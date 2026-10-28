import CLIKit
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Dependencies
import Fetch
import Foundation
import MachineContract
import Scratch
import Serve
import ServeTesting
import SpaceCore
@testable import SpaceServer
import Testing

final class MachineCLIHarness: Sendable {
  static let serverFingerprint = "sha256:" + String(repeating: "f", count: 64)

  let space: Space
  let hub: MachineHub
  let handler: UpgradingHandler
  let home: URL
  let cwd: URL
  let secrets: SpaceSecrets
  let scratch: ScratchFolder

  init() throws {
    scratch = try ScratchFolder("m6")
    let root = scratch.url
    home = root.appendingPathComponent("home", isDirectory: true)
    cwd = root.appendingPathComponent("work", isDirectory: true)
    let stores = SpaceSecretStores(configDirectory: root.appendingPathComponent("config", isDirectory: true), spaceID: "spc_test")
    secrets = try stores.group("shared")
    let wallet = cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wallet, withIntermediateDirectories: true)
    try Data("{\"space\":\"machine.test:1\"}".utf8).write(to: wallet.appendingPathComponent("config.json"))

    let space = try withDependencies {
      $0.date = DateGenerator { Date() }
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    } operation: {
      try Space.inMemory()
    }
    let hub = MachineHub(space: space, tokens: nil, secrets: stores)
    self.space = space
    self.hub = hub
    handler = SpaceServer.configuredHandler(space: space, hub: hub, fingerprint: Self.serverFingerprint, dev: true, secrets: stores, machineV2Hub: MachineV2Hub(space: space))
  }

  func runScenario(_ body: @escaping @Sendable (MachineCLIHarness) async throws -> Void) async throws {
    do {
      try await body(self)
      await hub.callerScope.close()
    } catch {
      await hub.callerScope.close()
      throw error
    }
  }

  func run(_ arguments: [String], io: CLIIO = CLIIO()) async -> Int32 {
    let client = fetchClient()
    let runner = CommandRunner(
      fetch: client,
      observeFetch: client,
      stdin: { io.stdinText },
      stdout: { text in await io.appendOut(Array(text.utf8)) },
      stderr: { text in await io.appendErr(Array(text.utf8)) },
      stdinIsTerminal: io.stdinIsTerminal,
      stdinChunks: { io.stdinStream },
      stdoutBytes: { bytes in await io.appendOut(bytes) },
      stderrBytes: { bytes in await io.appendErr(bytes) },
      environment: ["HOME": home.path],
      currentDirectory: cwd.path,
    )
    return await withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      await runner.run(arguments: arguments)
    }
  }

  func fetchClient() -> FetchClient {
    ServeTesting.client(upgrading: handler)
  }
}

final class CLIIO: Sendable {
  let stdinIsTerminal: Bool
  let stdinText: String
  let stdinStream: AsyncStream<[UInt8]>
  private let stdinContinuation: AsyncStream<[UInt8]>.Continuation
  private let out = ByteSink()
  private let err = ByteSink()

  init(stdin: String = "", terminal: Bool = false, interactive: Bool = false) {
    stdinIsTerminal = terminal
    stdinText = stdin
    (stdinStream, stdinContinuation) = AsyncStream.makeStream()
    if !stdin.isEmpty {
      stdinContinuation.yield(Array(stdin.utf8))
    }
    if !interactive {
      stdinContinuation.finish()
    }
  }

  func sendStdin(_ text: String) {
    stdinContinuation.yield(Array(text.utf8))
  }

  func closeStdin() {
    stdinContinuation.finish()
  }

  func appendOut(_ bytes: [UInt8]) async {
    await out.append(bytes)
  }

  func appendErr(_ bytes: [UInt8]) async {
    await err.append(bytes)
  }

  func stdoutBytes() async -> [UInt8] {
    await out.bytes
  }

  func stdoutText() async -> String {
    String(decoding: await out.bytes, as: UTF8.self)
  }

  func stderrText() async -> String {
    String(decoding: await err.bytes, as: UTF8.self)
  }
}

private actor ByteSink {
  var bytes: [UInt8] = []

  func append(_ more: [UInt8]) {
    bytes += more
  }
}

struct SeededRNG: RandomNumberGenerator, Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed &+ 0x9E37_79B9_7F4A_7C15
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct RegisteredMachine {
  let id: String
  let token: String
}

extension MachineCLIHarness {
  func addMachine() async throws -> RegisteredMachine {
    let io = CLIIO()
    let code = await run(["machine-v2", "add", "--name", "box"], io: io)
    let stderr = await io.stderrText()
    try #require(code == 0, "\(stderr)")
    let lines = await io.stdoutText().split(separator: "\n").map(String.init)
    let id = String(try #require(lines.first).dropFirst("machine ".count))
    let token = String(try #require(lines.dropFirst().first).dropFirst("token ".count))
    #expect(MachineID.isValid(id))
    #expect(JoinToken.isValid(token))
    return RegisteredMachine(id: id, token: token)
  }

  func machineListText() async -> String {
    let io = CLIIO()
    #expect(await run(["machine", "list"], io: io) == 0)
    return await io.stdoutText()
  }
}
