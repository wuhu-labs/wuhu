import CLIKit
import Clocks
import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import Scratch
import Serve
import ServeTesting
import SpaceCore
import SpaceServer
import Synchronization
import Testing

// The M6 faithfulness rig: a real SpaceServer handler + hub + Space, the real
// MachineAgent driven through the real `wuhu machine run` verb, and the CLI
// dialing WebSocket.pair() legs through the real upgrade routes — no sockets.
final class MachineCLIHarness: Sendable {
  static let serverFingerprint = "sha256:" + String(repeating: "f", count: 64)

  let space: Space
  let hub: MachineHub
  let handler: UpgradingHandler
  let clock: TestClock<Duration>
  let home: URL
  let cwd: URL
  let box: URL
  let secrets: SpaceSecrets
  let scratch: ScratchFolder

  private let jobs: AsyncStream<@Sendable () async -> Void>
  private let jobsContinuation: AsyncStream<@Sendable () async -> Void>.Continuation
  private let sockets = Mutex<[(path: String, socket: WebSocket)]>([])
  private let blockedDialPrefixes = Mutex<[String]>([])

  init() throws {
    scratch = try ScratchFolder("m6")
    let root = scratch.url
    home = root.appendingPathComponent("home", isDirectory: true)
    cwd = root.appendingPathComponent("work", isDirectory: true)
    box = root.appendingPathComponent("box", isDirectory: true)
    let stores = SpaceSecretStores(configDirectory: root.appendingPathComponent("config", isDirectory: true), spaceID: "spc_test")
    secrets = try stores.group("shared")
    let wallet = cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wallet, withIntermediateDirectories: true)
    try Data("{\"space\":\"machine.test:1\"}".utf8).write(to: wallet.appendingPathComponent("config.json"))

    let clock = TestClock<Duration>()
    let space = try withDependencies {
      $0.date = DateGenerator { Date() }
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    } operation: {
      try Space.inMemory()
    }
    let hub = withDependencies {
      $0.continuousClock = clock
    } operation: {
      MachineHub(space: space)
    }
    self.clock = clock
    self.space = space
    self.hub = hub
    handler = SpaceServer.handler(space: space, hub: hub, fingerprint: Self.serverFingerprint, dev: true, secrets: stores)
    (jobs, jobsContinuation) = AsyncStream.makeStream()
  }

  func runScenario(_ body: @escaping @Sendable (MachineCLIHarness) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await self.hub.run() }
      group.addTask {
        await withDiscardingTaskGroup { jobGroup in
          for await job in self.jobs {
            jobGroup.addTask { await job() }
          }
        }
      }
      group.addTask { try await body(self) }
      _ = try await group.next()
      group.cancelAll()
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
      dial: { url, headers in try await self.dial(url, headers: headers) },
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

  func http(_ method: Fetch.Method, _ path: String, json: JSONValue? = nil) async throws -> Response {
    var request = Request(url: URL(string: "http://machine.test:1\(path)")!, method: method)
    if let json {
      request.body = .bytes(Data(json.jsonString().utf8), contentType: "application/json")
    }
    return try await fetchClient()(request)
  }

  func dial(_ url: URL, headers: [(String, String)]) async throws -> any FrameTransport {
    let path = url.path
    if blockedDialPrefixes.withLock({ prefixes in prefixes.contains { path.hasPrefix($0) } }) {
      throw DialBlocked()
    }
    var requestHeaders = RequestHeaders()
    requestHeaders.set("connection", "Upgrade")
    requestHeaders.set("upgrade", "websocket")
    requestHeaders.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    requestHeaders.set("sec-websocket-version", "13")
    for (name, value) in headers {
      requestHeaders.set(name, value)
    }
    let request = Request(url: url, headers: requestHeaders)
    switch try await ServeTesting.upgrade(handler, request) {
    case let .response(response):
      throw DialRefused(status: response.status.code)
    case let .webSocket(client, serve):
      jobsContinuation.yield(serve)
      sockets.withLock { $0.append((path: path, socket: client)) }
      let (inbound, continuation) = AsyncStream<[UInt8]>.makeStream()
      jobsContinuation.yield {
        for await message in client.inbound {
          switch message {
          case let .binary(bytes): continuation.yield(bytes)
          case let .text(text): continuation.yield(Array(text.utf8))
          }
        }
        continuation.finish()
      }
      return HarnessTransport(socket: client, inbound: inbound)
    }
  }

  func dialMachineConnect(key: Curve25519.Signing.PrivateKey) async throws -> any FrameTransport {
    let challenge = try await http(.get, "/v1/machine/challenge").json(MachineChallengeOutput.self).challenge
    let signature = try key.signature(for: MachineConnect.signingPayload(challenge: challenge))
    return try await dial(
      URL(string: "http://machine.test:1/v1/machine/connect")!,
      headers: [
        (MachineConnect.pubkeyHeader, "ed25519:" + key.publicKey.rawRepresentation.base64EncodedString()),
        (MachineConnect.challengeHeader, challenge),
        (MachineConnect.signatureHeader, signature.base64EncodedString()),
      ],
    )
  }

  // The key the box persisted at `machine join`, read back the way the agent
  // reads it.
  func boxMachineKey() throws -> Curve25519.Signing.PrivateKey {
    let file = home.appendingPathComponent(".wuhu/machine/machine.key")
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: text)!)
  }

  func severSockets(pathPrefix: String) {
    let matching = sockets.withLock { all in all.filter { $0.path.hasPrefix(pathPrefix) } }
    for entry in matching {
      entry.socket.close()
    }
  }

  func blockDials(pathPrefix: String) {
    blockedDialPrefixes.withLock { $0.append(pathPrefix) }
  }
}

struct HarnessTransport: FrameTransport {
  let socket: WebSocket
  let inbound: AsyncStream<[UInt8]>

  func send(_ frame: [UInt8]) async throws {
    try await socket.send(.binary(frame))
  }

  func close() {
    socket.close()
  }
}

struct DialRefused: Error {
  let status: Int
}

struct DialBlocked: Error {}

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

func pollUntil(attempts: Int = 500, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
  let clock = ContinuousClock()
  for _ in 0 ..< attempts {
    if try await condition() { return true }
    try await clock.sleep(for: .milliseconds(10))
  }
  return false
}

func settleScheduledTimers() async {
  for _ in 0 ..< 50 {
    await Task.yield()
  }
}

// Shared scenario helpers

struct JoinedMachine {
  let id: String
  let token: String
}

extension MachineCLIHarness {
  func addAndJoin() async throws -> JoinedMachine {
    let addIO = CLIIO()
    #expect(await run(["machine", "add", "--name", "box"], io: addIO) == 0)
    let lines = await addIO.stdoutText().split(separator: "\n").map(String.init)
    let id = String(lines[0].dropFirst("machine ".count))
    let token = String(lines[1].dropFirst("token ".count))
    #expect(MachineID.isValid(id))
    #expect(JoinToken.isValid(token))
    #expect(await run(["machine", "join", "http://machine.test:1", "--name", "box"], io: CLIIO(stdin: token + "\n")) == 0)
    return JoinedMachine(id: id, token: token)
  }

  func machineListText() async -> String {
    let io = CLIIO()
    #expect(await run(["machine", "list"], io: io) == 0)
    return await io.stdoutText()
  }

  func waitAttached(_ id: String) async throws {
    #expect(try await pollUntil { await self.machineListText().contains("\(id) attached") })
  }

  func liveExecIDs() async throws -> [String] {
    let response = try await http(.get, "/v1/exec")
    let statuses = try await response.json([ExecStatus].self)
    return statuses.map(\.id.rawValue)
  }
}
