#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import ClaudeInstall
import Clocks
import Dependencies
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

private struct Offline: Error, CustomStringConvertible {
  var description: String { "registry unreachable" }
}

private final class Fixture: Sendable {
  let filesystem = NodeTreeVFS(root: InMemoryVFSNode())
  let downloads = Mutex<[Download]>([])
  let extractions = Mutex<[Extraction]>([])
  let permissions = Mutex<[String]>([])
  let offline = Mutex(false)
  let binary = Data("fixture Claude Code binary".utf8)
  let sdkArchive = Data("fixture SDK tarball".utf8)
  let binaryArchive = Data("fixture platform tarball".utf8)
  let clock = TestClock<Duration>()
  // Each download waits here for one element when set.
  let gate: AsyncStream<Void>?
  let entered: AsyncStream<Void>.Continuation?

  init(gate: AsyncStream<Void>? = nil, entered: AsyncStream<Void>.Continuation? = nil) {
    self.gate = gate
    self.entered = entered
  }

  func environment(platform: String?, checksum: String? = nil, size: Int? = nil, version: String = ClaudeInstaller.version) -> ClaudeInstallEnvironment {
    let manifest = Data("""
    {"version":"\(version)","platforms":{"\(platform ?? "none")":{
      "binary":"claude","checksum":"\(checksum ?? ClaudeInstaller.sha256(self.binary))","size":\(size ?? self.binary.count)
    }}}
    """.utf8)
    return ClaudeInstallEnvironment(
      platform: platform,
      fetch: FetchClient { request in
        self.downloads.withLock { $0.append(Download(url: request.url.absoluteString)) }
        self.entered?.yield()
        if let gate = self.gate {
          var iterator = gate.makeAsyncIterator()
          _ = await iterator.next()
          try Task.checkCancellation()
        }
        if self.offline.withLock({ $0 }) { throw Offline() }
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

  func installer(platform: String? = "darwin-arm64") -> ClaudeInstaller {
    installer(environment: environment(platform: platform))
  }

  func installer(environment: ClaudeInstallEnvironment) -> ClaudeInstaller {
    withDependencies { $0.continuousClock = clock } operation: {
      ClaudeInstaller(configDirectory: URL(fileURLWithPath: "/config"), environment: environment)
    }
  }
}

@Suite struct ClaudeInstallerTests {
  @Test(arguments: ["darwin-arm64", "linux-x64"])
  func downloadsPlatformPackageAndInstallsVerifiedBinary(platform: String) async throws {
    let fixture = Fixture()
    let installer = fixture.installer(platform: platform)
    let target = try await installer.install()
    #expect(target.path == "/config/vendors/claude/2.1.284/claude")
    #expect(try await fixture.filesystem.readData(at: VFSPath(absoluteFilePath: target.path)) == fixture.binary)
    #expect(fixture.downloads.withLock { $0.map(\.url) } == [
      "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-0.3.284.tgz",
      "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk-\(platform)/-/claude-agent-sdk-\(platform)-0.3.284.tgz",
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
    let installer = fixture.installer(
      environment: fixture.environment(
        platform: "linux-x64",
        checksum: kind == "bad digest" ? String(repeating: "0", count: 64) : nil,
        size: kind == "bad size" ? 1 : nil,
        version: kind == "bad version" ? "2.1.258" : ClaudeInstaller.version,
      ),
    )
    await #expect(throws: (any Error).self) { try await installer.install() }
    #expect(try await fixture.filesystem.status(at: VFSPath(absoluteFilePath: installer.binaryPath.path)) == nil)
    #expect(fixture.permissions.withLock { $0.isEmpty })
    #expect(fixture.downloads.withLock { $0.count } == (kind == "bad version" ? 1 : 2))
  }

  @Test func anInstalledBinaryIsTakenOnAnyPlatform() async throws {
    let fixture = Fixture()
    _ = try await fixture.installer().install()
    let unsupported = fixture.installer(platform: nil)
    #expect(try await unsupported.install().path == "/config/vendors/claude/2.1.284/claude")
    #expect(fixture.downloads.withLock { $0.count } == 2)
  }
}

@Suite struct ClaudeCodeInstallationTests {
  @Test func aMissingBinaryIsInstalledOnce() async throws {
    let fixture = Fixture()
    let installation = ClaudeCodeInstallation(fixture.installer())
    #expect(try await installation.ready().path == "/config/vendors/claude/2.1.284/claude")
    #expect(try await installation.ready().path == "/config/vendors/claude/2.1.284/claude")
    #expect(fixture.downloads.withLock { $0.count } == 2)
    #expect(fixture.permissions.withLock { $0.count } == 1)
  }

  @Test func concurrentCallersShareOneInstall() async throws {
    let (gate, open) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let (entered, enter) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let fixture = Fixture(gate: gate, entered: enter)
    let installation = ClaudeCodeInstallation(fixture.installer())
    let first = Task { try await installation.ready() }
    var arrivals = entered.makeAsyncIterator()
    _ = await arrivals.next()
    // The install is held in its first download; callers arriving now must not start another.
    let others = (0 ..< 4).map { _ in Task { try await installation.ready() } }
    for _ in 0 ..< 8 { await Task.yield() }
    open.yield()
    open.yield()
    open.finish()
    #expect(try await first.value.path == "/config/vendors/claude/2.1.284/claude")
    for other in others {
      #expect(try await other.value.path == "/config/vendors/claude/2.1.284/claude")
    }
    #expect(fixture.downloads.withLock { $0.count } == 2)
    #expect(fixture.permissions.withLock { $0.count } == 1)
  }

  @Test func aFailedInstallFailsItsCallersAndTheNextCallRetries() async throws {
    let fixture = Fixture()
    fixture.offline.withLock { $0 = true }
    let installation = ClaudeCodeInstallation(fixture.installer())
    let error = await #expect(throws: (any Error).self) { try await installation.ready() }
    #expect(error.map { "\($0)" } == "registry unreachable")
    #expect(fixture.downloads.withLock { $0.count } == 1)

    fixture.offline.withLock { $0 = false }
    #expect(try await installation.ready().path == "/config/vendors/claude/2.1.284/claude")
    #expect(fixture.downloads.withLock { $0.count } == 3)
    #expect(try await fixture.filesystem.readData(at: VFSPath(absoluteFilePath: "/config/vendors/claude/2.1.284/claude")) == fixture.binary)
  }

  @Test func aCancelledCallerStopsWaitingWhileTheInstallGoesOn() async throws {
    let (gate, open) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let (entered, enter) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let fixture = Fixture(gate: gate, entered: enter)
    let installation = ClaudeCodeInstallation(fixture.installer())
    let first = Task { try await installation.ready() }
    var arrivals = entered.makeAsyncIterator()
    _ = await arrivals.next()
    let second = Task { try await installation.ready() }
    first.cancel()
    // The install is still held in its first download.
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(fixture.downloads.withLock { $0.count } == 1)
    open.yield()
    open.yield()
    open.finish()
    #expect(try await second.value.path == "/config/vendors/claude/2.1.284/claude")
    #expect(fixture.downloads.withLock { $0.count } == 2)
    #expect(fixture.permissions.withLock { $0.count } == 1)
  }

  @Test func aDownloadThatNeverFinishesFailsAtTheDeadlineAndTheNextCallRetries() async throws {
    let (gate, hold) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let (entered, enter) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    let fixture = Fixture(gate: gate, entered: enter)
    let installation = ClaudeCodeInstallation(fixture.installer())
    let first = Task { try await installation.ready() }
    var arrivals = entered.makeAsyncIterator()
    _ = await arrivals.next()
    await fixture.clock.advance(by: .seconds(599))
    await fixture.clock.advance(by: .seconds(1))
    let error = await #expect(throws: (any Error).self) { try await first.value }
    #expect(error.map { "\($0)" } == "Claude Code 2.1.284 did not download within 10 minutes")
    #expect(fixture.downloads.withLock { $0.count } == 1)
    #expect(fixture.permissions.withLock { $0.isEmpty })

    // The stalled download was cancelled, which ends the gate: the retry goes straight through.
    #expect(try await installation.ready().path == "/config/vendors/claude/2.1.284/claude")
    #expect(fixture.downloads.withLock { $0.count } == 3)
    withExtendedLifetime(hold) {}
  }
}
