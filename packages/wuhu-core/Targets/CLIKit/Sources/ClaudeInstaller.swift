#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum ClaudeStream.ClaudeCode
import Dependencies
import Fetch
import WuhuVFS

struct ClaudeInstallEnvironment: Sendable {
  var fetch: FetchClient
  var extract: @Sendable (Data, String) async throws -> Data
  var filesystem: any VirtualFileSystem
  var makeExecutable: @Sendable (String) async throws -> Void

  init(
    fetch: FetchClient,
    extract: @escaping @Sendable (Data, String) async throws -> Data,
    filesystem: any VirtualFileSystem,
    makeExecutable: @escaping @Sendable (String) async throws -> Void,
  ) {
    self.fetch = fetch
    self.extract = extract
    self.filesystem = filesystem
    self.makeExecutable = makeExecutable
  }
}

extension ClaudeInstallEnvironment: TestDependencyKey {
  static var testValue: ClaudeInstallEnvironment {
    ClaudeInstallEnvironment(
      fetch: FetchClient { _ in throw CLIError(message: "Claude installer fetch not supplied") },
      extract: { _, _ in throw CLIError(message: "Claude installer extractor not supplied") },
      filesystem: NodeTreeVFS(root: InMemoryVFSNode()),
      makeExecutable: { _ in throw CLIError(message: "Claude installer permissions not supplied") },
    )
  }
}

struct ClaudeInstaller {
  static let version = ClaudeCode.version
  static let sdkVersion = "0.3.\(version.split(separator: ".").last!)"

  let configDirectory: URL
  let environment: ClaudeInstallEnvironment
  let platform: String

  init(configDirectory: URL, environment: ClaudeInstallEnvironment, platform: String? = Self.platform) throws {
    guard let platform, ["darwin-arm64", "linux-x64"].contains(platform) else {
      throw CLIError(message: "Claude Code \(Self.version) is available only on macOS arm64 and Linux amd64")
    }
    self.configDirectory = configDirectory
    self.environment = environment
    self.platform = platform
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

  static var platform: String? {
    #if os(macOS) && arch(arm64)
      "darwin-arm64"
    #elseif os(Linux) && arch(x86_64)
      "linux-x64"
    #else
      nil
    #endif
  }

  var binaryPath: URL {
    configDirectory.appendingPathComponent("vendors/claude/\(Self.version)/claude")
  }

  func install() async throws -> URL {
    let platform = self.platform
    let fs = environment.filesystem
    let destination = try VFSPath(absoluteFilePath: binaryPath.path)
    if let status = try await fs.status(at: destination) {
      guard status.kind == .file else { throw CLIError(message: "Claude Code install path is not a file: \(binaryPath.path)") }
      return binaryPath
    }

    let sdkURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-\(Self.sdkVersion).tgz")!
    let sdkArchive = try await download(sdkURL, limit: 32 << 20)
    let manifestData = try await environment.extract(sdkArchive, "package/manifest.json")
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    guard manifest.version == Self.version, let expected = manifest.platforms[platform], expected.binary == "claude",
          expected.checksum.count == 64, expected.checksum.allSatisfy(\.isHexDigit),
          expected.size > 0, expected.size < 512 << 20
    else { throw CLIError(message: "SDK \(Self.sdkVersion) has no valid Claude Code \(Self.version) manifest entry for \(platform)") }

    let package = "claude-agent-sdk-\(platform)"
    let binaryURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/\(package)/-/\(package)-\(Self.sdkVersion).tgz")!
    let archive = try await download(binaryURL, limit: 512 << 20)
    let binary = try await environment.extract(archive, "package/claude")
    let checksum = SHA256.hex(binary)
    guard binary.count == expected.size, checksum == expected.checksum.lowercased() else {
      throw CLIError(message: "Claude Code \(Self.version) \(platform) binary failed manifest verification: size \(binary.count)/\(expected.size), sha256 \(checksum)/\(expected.checksum)")
    }
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

  private func download(_ url: URL, limit: Int) async throws -> Data {
    let response = try await environment.fetch(Request(url: url))
    return try await response.validateStatus().data(upTo: limit)
  }
}
