import Clocks
import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
@testable import ExecSupervisor
import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import OperationRuntime
import Serve
import ServeTesting
import struct SpaceContract.EnrollConsumeOutput
import SpaceCore
@testable import SpaceServer
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

final class TestServer: Sendable {
  let space: Space
  let hub: MachineHub
  let handler: UpgradingHandler
  let api: FetchClient

  private let sessions: AsyncStream<@Sendable () async -> Void>
  private let sessionsContinuation: AsyncStream<@Sendable () async -> Void>.Continuation

  init(
    space: Space, clock: any NonsendingClock<Duration>, dev: Bool = true, tokens: ExecTokens? = nil,
    secrets: SpaceSecretStores? = nil,
  ) {
    self.space = space
    hub = withDependencies {
      $0.continuousClock = clock
      $0.date = DateGenerator { Date() }
    } operation: {
      MachineHub(space: space, tokens: tokens, secrets: secrets)
    }
    handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: dev, secrets: secrets, machineV2Hub: MachineV2Hub(space: space))
    api = ServeTesting.client(upgrading: handler)
    (sessions, sessionsContinuation) = AsyncStream.makeStream()
  }

  func run() async {
    await withDiscardingTaskGroup { group in
      for await job in sessions {
        group.addTask { await job() }
      }
    }
    await hub.callerScope.close()
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
  let key = Curve25519.Signing.PrivateKey()
  let response = try await server.http(.post, "/v1/machine-v2", json: .object([
    "name": .string("box"), "pubkey": .string(key.pubkeyLabel),
  ]))
  #expect(response.status == .ok)
  let output = try await response.json(EnrollConsumeOutput.self)
  return (MachineID(rawValue: try #require(output.machine)), key)
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

func withExecDescription<R>(space: Space, hub: MachineHub, machine: MachineID, _ body: () async throws -> R) async throws -> R {
  let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
  let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
  await hub.configureV2(service)
  return try await withThrowingTaskGroup(of: Void.self) { tasks in
    tasks.addTask { await agent.run() }
    tasks.addTask { try await service.run() }
    defer { tasks.cancelAll() }
    do {
      let result = try await body()
      await agent.shutdown(); await service.shutdown()
      return result
    } catch {
      await agent.shutdown(); await service.shutdown()
      throw error
    }
  }
}
