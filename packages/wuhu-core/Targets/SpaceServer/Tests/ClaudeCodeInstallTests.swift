@testable import ClaudeInstall
import enum ClaudeStream.ClaudeCode
import struct Credentials.CredentialResolver
import Crypto
import Dependencies
import Fetch
import Foundation
@testable import SpaceServer
import Synchronization
import Testing
import WuhuVFS

private struct Offline: Error, CustomStringConvertible {
  var description: String { "registry unreachable" }
}

@Suite struct ClaudeCodeInstallTests {
  @Test func aSessionStartWaitsForTheInstallAndRetriesOneThatFailed() async throws {
    let offline = Mutex(true)
    let fetches = Mutex(0)
    let binary = Data("claude".utf8)
    let checksum = SHA256.hash(data: binary).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    let manifest = Data("""
    {"version":"\(ClaudeCode.version)","platforms":{"linux-x64":{"binary":"claude","checksum":"\(checksum)","size":\(binary.count)}}}
    """.utf8)
    let environment = ClaudeInstallEnvironment(
      platform: "linux-x64",
      fetch: FetchClient { _ in
        fetches.withLock { $0 += 1 }
        if offline.withLock({ $0 }) { throw Offline() }
        return Response(status: .ok, body: .bytes(Data("tarball".utf8)))
      },
      extract: { _, member in member == "package/manifest.json" ? manifest : binary },
      filesystem: NodeTreeVFS(root: InMemoryVFSNode()),
      makeExecutable: { _ in },
    )
    try await withSessionDeps {
      try await withDependencies { $0[ClaudeInstallEnvironment.self] = environment } operation: {
        let loopback = try await ClaudeCodeLoopback(credentials: CredentialResolver { _ in .claudeCodeOAuth("sk-ant-oat") })
        loopback.host.serveLoopback(on: "http://127.0.0.1:4100")
        let session = try await loopback.claudeSession()
        let path = loopback.config.path + "/vendors/claude/\(ClaudeCode.version)/claude"

        let error = await #expect(throws: (any Error).self) {
          _ = try await loopback.host.launchSpec(session: session, claudeSessionID: UUID(), resume: false)
        }
        #expect(error.map { "\($0)" } == "Claude Code \(ClaudeCode.version) could not be installed at \(path): registry unreachable")

        offline.withLock { $0 = false }
        let launched = try await loopback.host.launchSpec(session: session, claudeSessionID: UUID(), resume: false)
        #expect(launched.spec("/tmp/a", "cct_t").binary == path)
        #expect(fetches.withLock { $0 } == 3, "the second start installed again: the SDK, then the platform package")
      }
    }
  }
}
