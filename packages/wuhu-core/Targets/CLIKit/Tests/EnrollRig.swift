#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import Scratch
import ServeNIO
import ServeTLS
import SpaceCore
import SpaceServer
import Synchronization
import Testing

final class RigClock: Sendable {
  private let now: Mutex<Date>

  init(start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
    self.now = Mutex(start)
  }

  var current: Date { self.now.withLock { $0 } }

  func advance(by interval: TimeInterval) {
    self.now.withLock { $0 += interval }
  }

  var generator: DateGenerator {
    DateGenerator { self.current }
  }
}

final class RequestLog: Sendable {
  private let paths: Mutex<[String]> = Mutex([])

  func record(_ path: String) {
    self.paths.withLock { $0.append(path) }
  }

  var recorded: [String] { self.paths.withLock { $0 } }
}

struct BoundServer {
  let port: Int
  let space: String
  let fingerprint: String
}

struct EnrollRig {
  let scratch: ScratchFolder
  let root: URL
  let configDirectory: URL
  let space: Space
  let trust: ServerTrust
  let clock: RigClock

  init(clock: RigClock = RigClock()) throws {
    let scratch = try ScratchFolder("enroll")
    try self.init(
      scratch: scratch,
      root: scratch.url,
      space: Self.makeSpace(seed: 29, date: clock.generator),
      clock: clock,
    )
  }

  // A second device: fresh HOME and config, same server.
  init(sharing rig: EnrollRig) throws {
    try self.init(
      scratch: rig.scratch,
      root: rig.root.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true),
      space: rig.space,
      clock: rig.clock,
    )
  }

  private init(scratch: ScratchFolder, root: URL, space: Space, clock: RigClock) throws {
    self.scratch = scratch
    self.root = root
    self.space = space
    self.clock = clock
    configDirectory = root.appendingPathComponent("user-config", isDirectory: true)
    trust = ServerTrust(directory: configDirectory)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("work", isDirectory: true), withIntermediateDirectories: true,
    )
  }

  static func makeSpace(seed: UInt64, date: DateGenerator = DateGenerator { Date() }) throws -> Space {
    try withDependencies {
      $0.date = date
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: seed))
    } operation: {
      try Space.inMemory()
    }
  }

  func serving(
    space: Space? = nil,
    hosts: [String] = ["localhost", "127.0.0.1"],
    origin: String? = nil,
    dev: Bool = false,
    _ body: (BoundServer) async throws -> Void,
  ) async throws {
    let space = space ?? self.space
    let identity = try TLSIdentity.selfSigned(hosts: hosts)
    let fingerprint = try identity.fingerprint()
    let handler = withDependencies {
      $0.date = self.clock.generator
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 43))
    } operation: {
      let hub = MachineHub(space: space)
      return SpaceServer.handler(space: space, hub: hub, origin: origin, fingerprint: fingerprint, dev: dev, webApp: nil)
    }
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, tls: identity, upgrading: handler)
    do {
      let spaceID = try await space.identity().rawValue
      try await body(BoundServer(port: try #require(server.boundAddress.port), space: spaceID, fingerprint: fingerprint))
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  func pinWallet(to space: String) throws {
    let wallet = root.appendingPathComponent("work/.wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: wallet, withIntermediateDirectories: true)
    try Data("{\"space\":\"\(space)\"}".utf8).write(to: wallet.appendingPathComponent("config.json"))
  }

  var walletDirectory: URL {
    root.appendingPathComponent("work/.wuhu", isDirectory: true)
  }

  // `plain` stands in for system trust; by default nothing may reach it.
  func run(
    _ arguments: [String], io: CLIIO = CLIIO(), log: RequestLog? = nil, plain: FetchClient? = nil,
  ) async -> Int32 {
    let plain = plain ?? FetchClient { request in
      Issue.record("enrollment traffic must not reach the plain client: \(request.url)")
      throw FetchError.unimplemented
    }
    let pinned = SpaceTransport.fetchClient(trust: trust, timeout: .seconds(10), plain: plain)
    let fetch = FetchClient { request in
      log?.record(request.url.path)
      return try await pinned(request)
    }
    let runner = CommandRunner(
      fetch: fetch,
      stdin: { io.stdinText },
      stdout: { text in await io.appendOut(Array(text.utf8)) },
      stderr: { text in await io.appendErr(Array(text.utf8)) },
      environment: [
        "HOME": root.appendingPathComponent("home").path,
        "WUHU_CONFIG_DIR": configDirectory.path,
      ],
      currentDirectory: root.appendingPathComponent("work").path,
    )
    return await withDependencies {
      $0.date = self.clock.generator
      $0.continuousClock = ContinuousClock()
    } operation: {
      await runner.run(arguments: arguments)
    }
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }
}
