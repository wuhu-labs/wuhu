#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Fetch
import Synchronization
import Testing
import WuhuVFS

private struct Download: Equatable {
  let url: String
}

private struct Extraction: Equatable {
  let member: String
  let archive: Data
}

private final class Fixture: Sendable {
  let filesystem = NodeTreeVFS(root: InMemoryVFSNode())
  let downloads = Mutex<[Download]>([])
  let extractions = Mutex<[Extraction]>([])
  let permissions = Mutex<[String]>([])
  let binary = Data("fixture Claude Code binary".utf8)
  let sdkArchive = Data("fixture SDK tarball".utf8)
  let binaryArchive = Data("fixture platform tarball".utf8)

  func environment(platform: String, checksum: String? = nil, size: Int? = nil, version: String = ClaudeInstaller.version) -> ClaudeInstallEnvironment {
    let manifest = Data("""
    {"version":"\(version)","platforms":{"\(platform)":{
      "binary":"claude","checksum":"\(checksum ?? SHA256.hex(self.binary))","size":\(size ?? self.binary.count)
    }}}
    """.utf8)
    return ClaudeInstallEnvironment(
      fetch: FetchClient { request in
        self.downloads.withLock { $0.append(Download(url: request.url.absoluteString)) }
        if request.url.absoluteString.contains("/claude-agent-sdk/-/") {
          return Response(status: .ok, body: .bytes(self.sdkArchive))
        }
        return Response(status: .ok, body: .bytes(self.binaryArchive))
      },
      extract: { archive, member in
        self.extractions.withLock { $0.append(Extraction(member: member, archive: archive)) }
        return member == "package/manifest.json" ? manifest : self.binary
      },
      filesystem: self.filesystem,
      makeExecutable: { path in self.permissions.withLock { $0.append(path) } },
    )
  }
}

@Suite struct ClaudeInstallerTests {
  @Test(arguments: ["darwin-arm64", "linux-x64"])
  func downloadsPlatformPackageAndInstallsVerifiedBinary(platform: String) async throws {
    let fixture = Fixture()
    let installer = try ClaudeInstaller(
      configDirectory: URL(fileURLWithPath: "/config"),
      environment: fixture.environment(platform: platform),
      platform: platform,
    )
    let target = try await installer.install()
    #expect(target.path == "/config/vendors/claude/2.1.280/claude")
    #expect(try await fixture.filesystem.readData(at: VFSPath(absoluteFilePath: target.path)) == fixture.binary)
    #expect(fixture.downloads.withLock { $0.map(\.url) } == [
      "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-0.3.280.tgz",
      "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk-\(platform)/-/claude-agent-sdk-\(platform)-0.3.280.tgz",
    ])
    #expect(fixture.extractions.withLock { $0.map(\.member) } == ["package/manifest.json", "package/claude"])
    #expect(fixture.extractions.withLock { $0.map(\.archive) } == [fixture.sdkArchive, fixture.binaryArchive])
    #expect(fixture.permissions.withLock { $0.count } == 1)
    _ = try await installer.install()
    #expect(fixture.downloads.withLock { $0.count } == 2)
  }

  @Test(arguments: ["bad digest", "bad size", "bad version"])
  func rejectsMismatchBeforeWriting(kind: String) async throws {
    let fixture = Fixture()
    let installer = try ClaudeInstaller(
      configDirectory: URL(fileURLWithPath: "/config"),
      environment: fixture.environment(
        platform: "linux-x64",
        checksum: kind == "bad digest" ? String(repeating: "0", count: 64) : nil,
        size: kind == "bad size" ? 1 : nil,
        version: kind == "bad version" ? "2.1.258" : ClaudeInstaller.version,
      ),
      platform: "linux-x64",
    )
    await #expect(throws: (any Error).self) { try await installer.install() }
    #expect(try await fixture.filesystem.status(at: VFSPath(absoluteFilePath: installer.binaryPath.path)) == nil)
    #expect(fixture.permissions.withLock { $0.isEmpty })
    #expect(fixture.downloads.withLock { $0.count } == (kind == "bad version" ? 1 : 2))
  }
}
