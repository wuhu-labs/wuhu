import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import LoopCore
import Serve
import ServeTesting
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

let testModelsJSON = """
{
  "testing": {
    "dialect": "anthropic",
    "baseURL": "http://localhost:1",
    "models": {
      "test-model": {
        "maxInput": 100000,
        "maxOutput": 1000,
        "efforts": ["low", "high"],
        "defaultEffort": "high"
      }
    }
  }
}
"""

// The session stack resolves uuid/date/clock through swift-dependencies; a
// test context must supply them, and the service must be constructed inside
// the same scope so its store inherits them.
func withSessionDeps<R>(_ body: () async throws -> R) async rethrows -> R {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.uuid = UUIDGenerator { UUID() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
  } operation: {
    try await body()
  }
}

struct SessionHarness {
  let space: Space
  let runtime: SessionRuntime
  let api: FetchClient
  let store: SessionStore
  let hub: MachineHub
  let handler: UpgradingHandler

  init(
    models: Bool = true,
    dev: Bool = true,
    origin: String? = nil,
    fingerprint: String? = nil,
    credentials: CredentialResolver = .unavailable,
    execTokens: ExecTokens? = nil,
    secrets: SpaceSecretStores? = nil,
    inference: @escaping @Sendable (LoopCore.InferenceRequest, AttemptHub) async throws -> LoopCore.InferenceReply = { _, _ in
      throw InferenceError.other(status: nil, body: "no inference scripted")
    },
  ) async throws {
    let space = try Space.inMemory()
    self.space = space
    store = space.sessions
    if models {
      _ = try await space.fs(.shared).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
    }
    let hub = MachineHub(space: space, tokens: execTokens)
    self.hub = hub
    let attempts = AttemptHub()
    let config = LoopConfig(
      executeTool: { _ in .failure(.init(message: "no tools in this harness")) },
      inference: { request in try await inference(request, attempts) },
      compact: { _, _ in CompactionResult(summary: "compacted") },
      budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
    )
    let service = await SessionService(sessions: store, loopConfig: config)
    runtime = SessionRuntime(space: space, service: service, attempts: attempts)
    handler = SpaceServer.configuredHandler(
      space: space, hub: hub, sessions: runtime, origin: origin, fingerprint: fingerprint, dev: dev, webApp: nil,
      credentials: credentials, secrets: secrets, execTokens: execTokens,
    )
    api = ServeTesting.client(upgrading: handler)
  }

  // .null means "no body" (the verb routes require an empty request).
  func post(_ path: String, _ body: JSONValue, bearer: String? = nil) async throws -> Response {
    var request = Request(url: URL(string: "http://space\(path)")!, method: .post)
    if body != .null {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    if let bearer {
      request.headers[.authorization] = "Bearer " + bearer
    }
    return try await api(request)
  }

  func call<Output: Decodable>(_ path: String, _ body: JSONValue, as _: Output.Type, bearer: String? = nil) async throws -> Output {
    let response = try await post(path, body, bearer: bearer)
    let text = try await response.text()
    #expect(response.status == .ok, "\(path): \(text)")
    return try JSONValueDecoder().decode(Output.self, from: try #require(JSONValue.parse(text)))
  }

  func put(_ path: String, _ body: JSONValue, bearer: String? = nil) async throws -> Response {
    var request = Request(url: URL(string: "http://space\(path)")!, method: .put)
    request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    if let bearer {
      request.headers[.authorization] = "Bearer " + bearer
    }
    return try await api(request)
  }

  func get(_ path: String, query: [String: String] = [:], bearer: String? = nil) async throws -> Response {
    var components = URLComponents(string: "http://space")!
    components.path = path
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var request = Request(url: components.url!)
    if let bearer {
      request.headers[.authorization] = "Bearer " + bearer
    }
    return try await api(request)
  }

  func mintPersona() async throws -> String {
    let account = try await space.addAccount(kind: .human, name: nil)
    let key = try await space.addKey(
      testPubkey(UUID().uuidString),
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    return try await space.mintPersona(key: key).name
  }

  init(assembledModels models: String) async throws {
    let space = try Space.inMemory()
    self.space = space
    store = space.sessions
    _ = try await space.fs(.shared).write("/models.json", Data(models.utf8), ifMatch: nil)
    let hub = MachineHub(space: space)
    self.hub = hub
    runtime = await SessionRuntime.assemble(
      space: space,
      hub: hub,
      credentials: CredentialResolver { providerID in
        .apiKey(CredentialResolver.environmentAPIKey(providerID) ?? "")
      },
    )
    handler = SpaceServer.handler(space: space, hub: hub, sessions: runtime, dev: true, webApp: nil)
    api = ServeTesting.client(upgrading: handler)
  }

  // Channel posts reach a session through the store's work signals, and only
  // the started service loop consumes those; `deliver` wakes the actor
  // without it.
  func deliver(_ text: String, to id: SessionID) async throws {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    _ = try await runtime.service.enqueue(item: .message(ConversationMessage(
      id: uuid(),
      messageID: MessageID(uuid().uuidString.lowercased()),
      conversationID: ConversationID(id.rawValue),
      sender: Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!),
      timestamp: date.now,
      content: MessageContent(text: text),
    )), to: id)
  }

  func running<R: Sendable>(_ body: () async throws -> R) async throws -> R {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [service = runtime.service] in try await service.start() }
      let result = try await body()
      group.cancelAll()
      try await group.waitForAll()
      return result
    }
  }

  func createSession(
    title: String = "test",
    kind: String = "agent",
    provider: String = "testing",
    model: String = "test-model",
  ) async throws -> SessionID {
    let output = try await call(
      "/v1/session",
      .object([
        "title": .string(title), "kind": .string(kind),
        "provider": .string(provider), "model": .string(model),
      ]),
      as: SessionCreateOutput.self,
    )
    return SessionID(output.id)
  }
}

func reply(_ text: String) -> LoopCore.InferenceReply {
  LoopCore.InferenceReply(
    message: AssistantMessage(content: [.text(.init(text: text))]),
    metadata: AssistantMessageMetadata(
      stopReason: .stop,
      usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10),
    ),
  )
}

final class Gate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func open() {
    continuation.finish()
  }

  func wait() async {
    for await _ in stream {}
  }
}

struct SessionTestTimeout: Error {}

func until(
  _ description: String,
  timeout: Duration = .seconds(10),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if try await condition() { return }
    try? await clock.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(description)")
  throw SessionTestTimeout()
}

func streamEvent(_ frameData: String) throws -> SessionStreamEvent {
  try JSONValueDecoder().decode(SessionStreamEvent.self, from: #require(JSONValue.parse(frameData)))
}

extension SessionStreamEvent {
  var isMaterialized: Bool {
    if case .materialized = self { return true }
    return false
  }
}
