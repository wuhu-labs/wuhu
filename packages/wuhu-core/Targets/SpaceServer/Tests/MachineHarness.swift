import Clocks
import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
@testable import ExecSupervisor
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import MachineChannel
import MachineContract
import OperationRuntime
import Serve
import ServeRouting
import ServeTesting
import struct SpaceContract.EnrollConsumeOutput
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

/// A response that fails at the transport is retried on the injected date a moment later; a suite with `\.date` pinned would never get there, so every test that drives a real tunnel runs its space on the live date, as production does.
func withLiveDate<R>(_ body: () async throws -> R) async throws -> R {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
  } operation: {
    try await body()
  }
}

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

func makeMachineSpace(seed: UInt64 = 7) throws -> Space {
  try withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: seed))
  } operation: {
    let space = try Space.inMemory()
    _ = space.worker
    return space
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
  ) async throws {
    self.space = space
    hub = withDependencies {
      $0.continuousClock = clock
      $0.date = DateGenerator { Date() }
    } operation: {
      MachineHub(space: space, tokens: tokens, secrets: secrets)
    }
    let devPerson = dev ? try await space.ensureDevPerson() : nil
    handler = SpaceServer.configuredHandler(space: space, hub: hub, devPerson: devPerson, secrets: secrets, listenerRoutes: machineListenerRoutes(space: space, hub: hub, devPerson: devPerson))
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

final class EndpointHost: Sendable {
  let endpoint: ChannelEndpoint = ChannelEndpoint()

  private let transports: AsyncStream<any FrameTransport>
  private let continuation: AsyncStream<any FrameTransport>.Continuation

  init() {
    (transports, continuation) = AsyncStream.makeStream()
  }

  func attach(_ socket: WebSocket) {
    attach(WebSocketTransport(socket) as any FrameTransport)
  }

  func attach(_ transport: any FrameTransport) {
    continuation.yield(transport)
  }

  func run() async {
    for await transport in transports {
      await endpoint.run(transport)
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
  return try await withThrowingTaskGroup(of: Void.self) { tasks in
    tasks.addTask { await agent.run() }
    defer { tasks.cancelAll() }
    do {
      let result = try await withMachineBox(space: space, hub: hub, machine: machine, client: FetchClient { try await agent.handler($0) }, body)
      await agent.shutdown()
      return result
    } catch {
      await agent.shutdown()
      throw error
    }
  }
}

func withMachineBox<R>(
  space: Space, hub: MachineHub, machine: MachineID, client: FetchClient,
  _ body: () async throws -> R,
) async throws -> R {
  let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
  let link = try #require(BoxLink(worker: space.worker, machine: machine.rawValue, pubkey: pubkey, connection: UUID(), streams: 1024, buffers: space.machineBuffers) {
    try await hub.prepare($0, machine: machine.rawValue)
  })
  return try await withThrowingTaskGroup(of: Void.self) { tasks in
    tasks.addTask { await link.run(client: client) }
    defer { link.close(); tasks.cancelAll() }
    try #require(try await realPollUntil { try await space.machineDescription(machine) != nil })
    return try await body()
  }
}

func machineListenerRoutes(
  space: Space, hub: MachineHub, devPerson: ResolvedPerson?, version: String = SpaceServer.unstampedVersion,
  fingerprint: String? = nil,
) -> Router {
  let upgrades = MachineV2Upgrades(space: space, serverVersion: version)
  var router = Router()
  addMachineV2Routes(&router, space: space, hub: hub, upgrades: upgrades, fingerprint: fingerprint) { request in
    @Dependency(\.date) var date
    return try await requestPrincipal(request, space: space, devPerson: devPerson, date: date)
  }
  return router
}
