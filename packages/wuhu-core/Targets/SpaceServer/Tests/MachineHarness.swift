import Clocks
import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
import Fetch
import Foundation
import JSONValue
import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Serve
import ServeTesting
import SpaceCore
import SpaceServer
import Synchronization
import Testing

struct SeededRNG: RandomNumberGenerator, Sendable {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

func makeMachineSpace(file: URL? = nil, seed: UInt64 = 7) throws -> Space {
  try withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: seed))
  } operation: {
    if let file {
      return try Space.open(file: file)
    }
    return try Space.inMemory()
  }
}

// One server incarnation: a hub + handler over a Space. Sessions accepted via
// the real handler are hosted on an internal stream so tests drive everything
// from one task group; a "server restart" is simply a fresh TestServer over
// the same Space with the old one's run task cancelled.
final class TestServer: Sendable {
  let space: Space
  let hub: MachineHub
  let handler: UpgradingHandler
  let api: FetchClient

  private let sessions: AsyncStream<@Sendable () async -> Void>
  private let sessionsContinuation: AsyncStream<@Sendable () async -> Void>.Continuation

  init(
    space: Space, clock: any Clock<Duration>, grace: Duration = .seconds(60), dev: Bool = true, tokens: ExecTokens? = nil,
    secrets: SpaceSecretStores? = nil,
    callerGrace: Duration? = nil, keyRecheck: Duration = .seconds(30),
  ) {
    self.space = space
    hub = withDependencies {
      $0.continuousClock = clock
      $0.date = DateGenerator { Date() }
    } operation: {
      MachineHub(space: space, callerGrace: callerGrace ?? grace, machineGrace: grace, keyRecheck: keyRecheck, tokens: tokens, secrets: secrets)
    }
    handler = SpaceServer.handler(space: space, hub: hub, dev: dev, secrets: secrets)
    api = ServeTesting.client(upgrading: handler)
    (sessions, sessionsContinuation) = AsyncStream.makeStream()
  }

  func run() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.hub.run() }
      group.addTask {
        await withDiscardingTaskGroup { sessionGroup in
          for await job in self.sessions {
            sessionGroup.addTask { await job() }
          }
        }
      }
      await group.waitForAll()
    }
  }

  func http(_ method: Fetch.Method, _ path: String, json: JSONValue? = nil) async throws -> Response {
    var request = Request(url: URL(string: "http://space\(path)")!, method: method)
    if let json {
      request.body = .bytes(Data(json.jsonString().utf8), contentType: "application/json")
    }
    return try await api(request)
  }

  enum Opened {
    case socket(WebSocket)
    case refused(Response)
  }

  func openWebSocket(_ path: String, headers: [(String, String)] = []) async throws -> Opened {
    var requestHeaders = RequestHeaders()
    requestHeaders.set("connection", "Upgrade")
    requestHeaders.set("upgrade", "websocket")
    requestHeaders.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    requestHeaders.set("sec-websocket-version", "13")
    for (name, value) in headers {
      requestHeaders.set(name, value)
    }
    let request = Request(url: URL(string: "http://space\(path)")!, headers: requestHeaders)
    switch try await ServeTesting.upgrade(handler, request) {
    case let .response(response):
      return .refused(response)
    case let .webSocket(client, serve):
      sessionsContinuation.yield(serve)
      return .socket(client)
    }
  }

  func requireSocket(_ path: String, headers: [(String, String)] = []) async throws -> WebSocket {
    switch try await openWebSocket(path, headers: headers) {
    case let .socket(socket): return socket
    case let .refused(response): throw UnexpectedResponse(status: response.status)
    }
  }
}

struct UnexpectedResponse: Error {
  let status: Status
}

// Feeds the agent's reconnect loop: each yielded socket is one connection.
final class AgentDialer: Sendable {
  private let sockets: AsyncStream<WebSocket>
  private let continuation: AsyncStream<WebSocket>.Continuation

  init() {
    (sockets, continuation) = AsyncStream.makeStream()
  }

  func offer(_ socket: WebSocket) {
    continuation.yield(socket)
  }

  var dial: @Sendable () async throws -> any FrameTransport {
    { [sockets] in
      for await socket in sockets {
        return WebSocketTransport(socket)
      }
      throw ChannelError.severed
    }
  }
}

// A caller-leg ChannelEndpoint driven by a feed of transports: each attached
// socket is one connection round; endpoint state survives across them.
final class EndpointHost: Sendable {
  let endpoint: ChannelEndpoint = ChannelEndpoint()

  private let transports: AsyncStream<any FrameTransport>
  private let continuation: AsyncStream<any FrameTransport>.Continuation
  private let finishedRounds = Mutex(0)

  init() {
    (transports, continuation) = AsyncStream.makeStream()
  }

  func attach(_ socket: WebSocket) {
    attach(WebSocketTransport(socket) as any FrameTransport)
  }

  func attach(_ transport: any FrameTransport) {
    continuation.yield(transport)
  }

  var completedRounds: Int {
    finishedRounds.withLock { $0 }
  }

  func run() async {
    for await transport in transports {
      await endpoint.run(transport)
      finishedRounds.withLock { $0 += 1 }
    }
  }
}

final class OutputByteCounter: Sendable {
  private let count = Mutex(0)

  var value: Int {
    count.withLock { $0 }
  }

  func add(_ n: Int) {
    count.withLock { $0 += n }
  }
}

// Counts output payload bytes as they come off the socket, so a test can know
// the machine's full send window is already delivered before it severs a leg.
final class CountingTransport: FrameTransport, Sendable {
  let inbound: AsyncStream<[UInt8]>
  private let base: any FrameTransport

  init(_ base: any FrameTransport, counter: OutputByteCounter) {
    self.base = base
    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    inbound = stream
    let upstream = base.inbound
    Task {
      for await bytes in upstream {
        if let frame = try? FrameCodec.decode(bytes), frame.opcode == .output,
           let chunk = try? frame.payload(OutputChunk.self)
        {
          counter.add(chunk.data.count)
        }
        continuation.yield(bytes)
      }
      continuation.finish()
    }
  }

  func send(_ frame: [UInt8]) async throws {
    try await base.send(frame)
  }

  func close() {
    base.close()
  }
}

func patternBytes(_ count: Int) -> [UInt8] {
  (0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ ($0 >> 8)) }
}

func consumeOutput(_ iterator: inout ExecEvents.Iterator, atLeast target: Int) async throws -> [UInt8] {
  var collected: [UInt8] = []
  while collected.count < target {
    guard let event = try await iterator.next() else { return collected }
    if case let .output(_, _, data) = event {
      collected += data.bytes
    }
  }
  return collected
}

func drainToExit(_ iterator: inout ExecEvents.Iterator) async throws -> (stdout: [UInt8], exit: MachineContract.ExitStatus?) {
  var stdout: [UInt8] = []
  while let event = try await iterator.next() {
    switch event {
    case let .output(stream, _, data) where stream == .stdout:
      stdout += data.bytes
    case let .exit(status):
      return (stdout, status)
    default:
      continue
    }
  }
  return (stdout, nil)
}

func makeAgent(state: ScratchFolder, killGrace: Duration = .milliseconds(300)) -> MachineAgent {
  withDependencies {
    $0.continuousClock = ContinuousClock()
  } operation: {
    MachineAgent(stateDirectory: state.path, killGrace: killGrace)
  }
}

extension Curve25519.Signing.PrivateKey {
  var pubkeyLabel: String {
    "ed25519:" + publicKey.rawRepresentation.base64EncodedString()
  }
}

extension P256.Signing.PrivateKey {
  var pubkeyLabel: String {
    "p256:" + publicKey.x963Representation.base64EncodedString()
  }
}

func addMachine(_ server: TestServer) async throws -> (id: MachineID, key: Curve25519.Signing.PrivateKey) {
  let response = try await server.http(.post, "/v1/machine", json: .object(["name": .string("box")]))
  #expect(response.status == .ok)
  let output = try await response.json(MachineAddOutput.self)
  let key = try await enrollMachineKey(server, token: output.token)
  return (output.id, key)
}

func enrollMachineKey(_ server: TestServer, token: String) async throws -> Curve25519.Signing.PrivateKey {
  let key = Curve25519.Signing.PrivateKey()
  let consumed = try await server.http(.post, "/v1/enroll/consume", json: .object([
    "token": .string(token), "pubkey": .string(key.pubkeyLabel),
  ]))
  #expect(consumed.status == .ok)
  return key
}

// `groupSecrets: false` dials as an agent from before the capabilities header.
func connectHeaders(
  _ server: TestServer, key: Curve25519.Signing.PrivateKey, groupSecrets: Bool = true,
) async throws -> [(String, String)] {
  let response = try await server.http(.get, "/v1/machine/challenge")
  #expect(response.status == .ok)
  let challenge = try await response.json(MachineChallengeOutput.self).challenge
  let signature = try key.signature(for: MachineConnect.signingPayload(challenge: challenge))
  let headers = [
    (MachineConnect.pubkeyHeader, key.pubkeyLabel),
    (MachineConnect.challengeHeader, challenge),
    (MachineConnect.signatureHeader, signature.base64EncodedString()),
  ]
  return groupSecrets ? headers + [(MachineConnect.capabilitiesHeader, MachineConnect.groupSecrets)] : headers
}

func connectMachine(
  _ server: TestServer, key: Curve25519.Signing.PrivateKey, groupSecrets: Bool = true,
) async throws -> WebSocket {
  try await server.requireSocket("/v1/machine/connect", headers: try await connectHeaders(server, key: key, groupSecrets: groupSecrets))
}

func mintExec(_ server: TestServer, machine: MachineID) async throws -> ExecID {
  let response = try await server.http(.post, "/v1/exec", json: .object(["machine": .string(machine.rawValue)]))
  #expect(response.status == .ok)
  return try await response.json(ExecMintOutput.self).id
}

func connectCaller(_ server: TestServer, exec: ExecID) async throws -> WebSocket {
  try await server.requireSocket("/v1/exec/\(exec.rawValue)")
}

func collectExec(_ exec: OutgoingExec) async throws -> (stdout: [UInt8], stderr: [UInt8], exit: MachineContract.ExitStatus?) {
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  for try await event in exec.events {
    switch event {
    case let .output(stream, _, data):
      switch stream {
      case .stdout: stdout += data.bytes
      case .stderr: stderr += data.bytes
      }
    case let .exit(status):
      return (stdout, stderr, status)
    default:
      continue
    }
  }
  return (stdout, stderr, nil)
}

func realPollUntil(attempts: Int = 500, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
  let clock = ContinuousClock()
  for _ in 0 ..< attempts {
    if try await condition() { return true }
    try await clock.sleep(for: .milliseconds(10))
  }
  return false
}
