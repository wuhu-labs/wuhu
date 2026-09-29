#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum ClaudeStream.ClaudeCode
import Crypto
import Dependencies
import Fetch
import WuhuVFS

public struct ClaudeInstallEnvironment: Sendable {
  /// The agent SDK's name for this host's platform package, `darwin-arm64` or `linux-x64`; nil where Claude Code does not ship.
  var platform: String?
  var fetch: FetchClient
  var extract: @Sendable (Data, String) async throws -> Data
  var filesystem: any VirtualFileSystem
  var makeExecutable: @Sendable (String) async throws -> Void

  init(
    platform: String?,
    fetch: FetchClient,
    extract: @escaping @Sendable (Data, String) async throws -> Data,
    filesystem: any VirtualFileSystem,
    makeExecutable: @escaping @Sendable (String) async throws -> Void,
  ) {
    self.platform = platform
    self.fetch = fetch
    self.extract = extract
    self.filesystem = filesystem
    self.makeExecutable = makeExecutable
  }
}

extension ClaudeInstallEnvironment: TestDependencyKey {
  /// Reads the real disk and never writes it, so a binary a test put in place is found and a missing one fails to install.
  public static var testValue: ClaudeInstallEnvironment {
    ClaudeInstallEnvironment(
      platform: nil,
      fetch: FetchClient { _ in throw ClaudeInstallError("Claude installer fetch not supplied") },
      extract: { _, _ in throw ClaudeInstallError("Claude installer extractor not supplied") },
      filesystem: NodeTreeVFS(root: DiskVFSNode(path: "/", isMutable: false)),
      makeExecutable: { _ in throw ClaudeInstallError("Claude installer permissions not supplied") },
    )
  }
}

/// A file already at ``binaryPath`` counts as installed, on any platform; nothing is downloaded then.
public struct ClaudeInstaller: Sendable {
  static let version = ClaudeCode.version
  static let sdkVersion = "0.3.\(version.split(separator: ".").last!)"

  static let downloadDeadline: Duration = .seconds(600)

  public let binaryPath: URL
  let environment: ClaudeInstallEnvironment
  let clock: any Clock<Duration>

  public init(configDirectory: URL, environment: ClaudeInstallEnvironment) {
    binaryPath = configDirectory.appendingPathComponent("vendors/claude/\(Self.version)/claude")
    self.environment = environment
    @Dependency(\.continuousClock) var clock
    self.clock = clock
  }

  struct Manifest: Decodable {
    struct Platform: Decodable {
      let binary: String
      let checksum: String
      let size: Int
    }

    let version: String
    let platforms: [String: Platform]
  }

  public func install() async throws -> URL {
    let fs = environment.filesystem
    let destination = try VFSPath(absoluteFilePath: binaryPath.path)
    if let status = try await fs.status(at: destination) {
      guard status.kind == .file else { throw ClaudeInstallError("Claude Code install path is not a file: \(binaryPath.path)") }
      return binaryPath
    }
    guard let platform = environment.platform, ["darwin-arm64", "linux-x64"].contains(platform) else {
      throw ClaudeInstallError("Claude Code \(Self.version) is available only on macOS arm64 and Linux amd64")
    }
    let binary = try await withinDeadline { try await verifiedBinary(platform: platform) }
    let parent = try VFSPath(absoluteFilePath: binaryPath.deletingLastPathComponent().path)
    try await fs.createDirectory(at: parent, intermediates: true)
    let staging = try VFSPath(absoluteFilePath: binaryPath.path + ".\(UUID().uuidString).tmp")
    do {
      try await fs.createFile(at: staging, data: binary)
      try await environment.makeExecutable(staging.absoluteFilePath)
      if try await fs.status(at: destination) == nil {
        try await fs.move(from: staging, to: destination)
      } else {
        try await fs.remove(at: staging, recursive: false)
      }
    } catch {
      try? await fs.remove(at: staging, recursive: false)
      throw error
    }
    return binaryPath
  }

  // A stalled download on a live connection never fails by itself, and an install in flight holds every Claude Code start.
  private func withinDeadline(_ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
    let clock = clock
    return try await withThrowingTaskGroup(of: Data?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await clock.sleep(for: Self.downloadDeadline)
        return nil
      }
      defer { group.cancelAll() }
      guard let binary = try await group.next() ?? nil else {
        throw ClaudeInstallError("Claude Code \(Self.version) did not download within 10 minutes")
      }
      return binary
    }
  }

  private func verifiedBinary(platform: String) async throws -> Data {
    let sdkURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-\(Self.sdkVersion).tgz")!
    let sdkArchive = try await download(sdkURL, limit: 32 << 20)
    let manifestData = try await environment.extract(sdkArchive, "package/manifest.json")
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.version == Self.version, let expected = manifest.platforms[platform], expected.binary == "claude",
          expected.checksum.count == 64, expected.checksum.allSatisfy(\.isHexDigit),
          expected.size > 0, expected.size < 512 << 20
    else { throw ClaudeInstallError("SDK \(Self.sdkVersion) has no valid Claude Code \(Self.version) manifest entry for \(platform)") }

    let package = "claude-agent-sdk-\(platform)"
    let binaryURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/\(package)/-/\(package)-\(Self.sdkVersion).tgz")!
    let archive = try await download(binaryURL, limit: 512 << 20)
    let binary = try await environment.extract(archive, "package/claude")
    let checksum = Self.sha256(binary)
    guard binary.count == expected.size, checksum == expected.checksum.lowercased() else {
      throw ClaudeInstallError("Claude Code \(Self.version) \(platform) binary failed manifest verification: size \(binary.count)/\(expected.size), sha256 \(checksum)/\(expected.checksum)")
    }
    return binary
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
  }

  private func download(_ url: URL, limit: Int) async throws -> Data {
    let response = try await environment.fetch(Request(url: url))
    return try await response.validateStatus().data(upTo: limit)
  }
}

struct ClaudeInstallError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
