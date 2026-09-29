#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import struct Fetch.FetchClient
import struct Fetch.Request
import struct Fetch.RequestHeaders
import struct Fetch.Response

struct UpgradeCommand: Equatable {
  var check: Bool
  var rollback: Bool
  var lane: ReleaseLane?
}

public struct UpgradeEnvironment: Sendable {
  public var fetch: FetchClient
  public var extract: @Sendable (_ archive: URL, _ into: URL) async throws -> Void

  public init(
    fetch: FetchClient,
    extract: @escaping @Sendable (_ archive: URL, _ into: URL) async throws -> Void,
  ) {
    self.fetch = fetch
    self.extract = extract
  }
}

extension UpgradeEnvironment: TestDependencyKey {
  public static var testValue: UpgradeEnvironment {
    struct Unimplemented: Error, CustomStringConvertible {
      let what: String
      var description: String { "UpgradeEnvironment.\(self.what) is unimplemented in tests" }
    }
    return UpgradeEnvironment(
      fetch: FetchClient { _ in throw Unimplemented(what: "fetch") },
      extract: { _, _ in throw Unimplemented(what: "extract") },
    )
  }
}

enum ReleasePlatform {
  static var current: (name: String, archiveExtension: String)? {
    #if os(macOS) && arch(arm64)
      ("macos-arm64", "zip")
    #elseif os(Linux) && arch(x86_64)
      ("linux-amd64", "tar.gz")
    #else
      nil
    #endif
  }
}

// Releases are published to the public wuhu.ai CDN, not to GitHub: discovery is
// one unauthenticated GET of the lane pointer, so upgrading needs no token and
// no account. The pointer carries each artifact's sha256, so verification needs
// no second request.
struct ReleaseChannel {
  static let baseURL = "https://wuhu.ai"

  var fetch: FetchClient

  struct Index: Decodable, Sendable {
    struct Artifact: Decodable, Sendable {
      let name: String
      let url: String
      let sha256: String
    }

    let version: String
    let artifacts: [String: Artifact]
  }

  func latest(lane: ReleaseLane) async throws -> Index {
    let url = URL(string: "\(Self.baseURL)/releases/\(lane.rawValue)/latest.json")!
    let response = try await self.fetch(Request(url: url, headers: self.headers()))
    guard response.status.code == 200 else {
      throw CLIError(message: """
      \(url.absoluteString) answered \(response.status.code)
      no published releases in the \(lane.rawValue) lane yet
      """)
    }
    return try await response.json(Index.self, upTo: 1 << 20)
  }

  func download(_ url: URL, upTo limit: Int) async throws -> Data {
    let response = try await self.fetch(Request(url: url, headers: self.headers()))
    return try await response.validateStatus().data(upTo: limit)
  }

  private func headers() -> RequestHeaders {
    var headers = RequestHeaders()
    headers.set("user-agent", "wuhu-upgrade")
    return headers
  }
}

struct UpgradeVerb {
  var runner: CommandRunner

  func run(_ command: UpgradeCommand) async throws {
    let layout = try UpgradeLayout.locate(environment: self.runner.environment)
    if command.rollback {
      let lock = try layout.acquireLock()
      defer { try? FileManager.default.removeItem(at: lock) }
      let flip = try layout.rollback()
      await self.runner.stdout("rolled back \(layout.currentBinary.path): \(flip.from) -> \(flip.to)\n")
      await self.warnAboutShadowing(layout)
      return
    }

    guard let platform = ReleasePlatform.current else {
      throw CLIError(message: "no prebuilt wuhu binaries for this platform; build from source instead")
    }
    let own = ReleaseVersion.parseStamped(self.runner.version)
    guard let lane = command.lane ?? own?.lane else {
      throw CLIError(message: """
      this binary carries no release lane (version \(self.runner.version))
      pick one explicitly: wuhu upgrade --lane dev|beta|release
      """)
    }

    @Dependency(UpgradeEnvironment.self) var environment
    let channel = ReleaseChannel(fetch: environment.fetch)
    let index = try await channel.latest(lane: lane)
    guard let latest = ReleaseVersion.parse(index.version) else {
      throw CLIError(message: "\(lane.rawValue) lane pointer names an unparseable version: \(index.version)")
    }
    guard latest.lane == lane else {
      throw CLIError(message: "\(lane.rawValue) lane pointer names \(latest), which is not a \(lane.rawValue) release")
    }

    let following = own.flatMap { $0.lane == lane ? $0 : nil }
    let upToDate = following.map { !latest.isNewer(than: $0) } ?? false
    if command.check {
      var text = "running \(self.runner.version); latest \(lane.rawValue) is \(latest)\n"
      text += upToDate ? "up to date\n" : "run wuhu upgrade\(command.lane.map { " --lane \($0.rawValue)" } ?? "") to install\n"
      await self.runner.stdout(text)
      return
    }
    if upToDate {
      await self.runner.stdout("up to date: \(latest) is the latest \(lane.rawValue) release\n")
      return
    }
    if layout.currentVersion() == latest.description, layout.versionDirectoryExists(latest.description) {
      if layout.holds(latest.description) {
        await self.runner.stdout("""
        \(layout.currentBinary.path) is already \(latest); this process runs \(self.runner.version)
        start a fresh shell (or rehash) to pick it up
        """ + "\n")
      } else {
        let lock = try layout.acquireLock()
        defer { try? FileManager.default.removeItem(at: lock) }
        try layout.flip(to: latest.description)
        await self.runner.stdout("installed \(latest) -> \(layout.currentBinary.path)\n")
      }
      await self.warnAboutShadowing(layout)
      return
    }

    let assetName = "wuhu-\(latest)-\(platform.name).\(platform.archiveExtension)"
    guard let artifact = index.artifacts[platform.name] else {
      throw CLIError(message: "\(lane.rawValue) lane pointer has no \(platform.name) artifact")
    }
    guard artifact.name == assetName else {
      throw CLIError(message: "\(lane.rawValue) lane pointer names \(artifact.name), not \(assetName); refusing")
    }
    guard let assetURL = URL(string: artifact.url) else {
      throw CLIError(message: "\(lane.rawValue) lane pointer has an unparseable url for \(platform.name): \(artifact.url)")
    }
    let expected = artifact.sha256.lowercased()
    guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
      throw CLIError(message: "malformed sha256 for \(assetName): \(artifact.sha256)")
    }
    await self.runner.stderr("downloading \(assetName)\n")
    let archive = try await channel.download(assetURL, upTo: 1 << 30)
    let actual = SHA256.hex(archive)
    guard actual == expected else {
      throw CLIError(message: "checksum mismatch for \(assetName): expected \(expected), downloaded \(actual)")
    }
    await self.runner.stderr("verified sha256:\(actual)\n")

    try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
    let lock = try layout.acquireLock()
    defer { try? FileManager.default.removeItem(at: lock) }
    let staging = try layout.stagingDirectory()
    do {
      let archiveFile = staging.appendingPathComponent(assetName)
      let payload = staging.appendingPathComponent("payload", isDirectory: true)
      try archive.write(to: archiveFile, options: .atomic)
      try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
      try await environment.extract(archiveFile, payload)
      try layout.install(payload: payload, version: latest.description)
      try layout.flip(to: latest.description)
      try? FileManager.default.removeItem(at: staging)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
    await self.runner.stdout("installed \(latest) -> \(layout.currentBinary.path)\n")
    do {
      for version in try layout.prune(keep: 3) {
        await self.runner.stderr("pruned \(version)\n")
      }
    } catch {
      await self.runner.stderr("warning: could not prune old versions: \(error)\n")
    }
    await self.warnAboutShadowing(layout)
  }

  private func warnAboutShadowing(_ layout: UpgradeLayout) async {
    guard let message = shadowWarning(
      path: self.runner.environment["PATH"],
      layout: layout,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      resolve: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
    ) else { return }
    await self.runner.stderr(message)
  }
}

func shadowWarning(
  path: String?,
  layout: UpgradeLayout,
  isExecutable: (String) -> Bool,
  resolve: (String) -> String,
) -> String? {
  let binDirectory = layout.root.standardizedFileURL.path
  guard let path else {
    return "warning: PATH is not set; \(layout.currentBinary.path) will not be found\n"
  }
  for entry in path.split(separator: ":") where !entry.isEmpty {
    let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
      .appendingPathComponent("wuhu").standardizedFileURL.path
    guard isExecutable(candidate) else { continue }
    if candidate == layout.currentBinary.standardizedFileURL.path { return nil }
    let resolved = resolve(candidate)
    if resolved.hasPrefix(resolve(binDirectory) + "/") { return nil }
    return "warning: \(candidate) shadows \(layout.currentBinary.path) on PATH; remove it or reorder PATH\n"
  }
  return "warning: \(binDirectory) is not on PATH; the installed wuhu will not be found\n"
}
