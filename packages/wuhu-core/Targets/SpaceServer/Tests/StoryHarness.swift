import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
@testable import ExecSupervisor
import InferenceKit
import JSONValue
import LoopCore
import MachineContract
import MainHub
import OperationRuntime
import Scratch
import Serve
import ServeTesting
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

// MARK: - The mini harness

// What the model answers next, made from the transcript it is asked with.
struct Reply: Sendable {
  var message: @Sendable ([TranscriptLine]) -> AssistantMessage

  static func say(_ text: String) -> Reply {
    Reply { _ in AssistantMessage(content: [.text(.init(text: text))]) }
  }

  static func call(_ tool: String, _ arguments: JSONValue) -> Reply {
    .call(tool) { _ in arguments }
  }

  static func call(_ tool: String, _ arguments: @escaping @Sendable ([TranscriptLine]) -> JSONValue) -> Reply {
    let id = "call-" + UUID().uuidString.lowercased().prefix(8)
    return Reply { AssistantMessage(content: [.toolCall(ToolCall(id: id, name: tool, arguments: ToolArguments(arguments($0))))]) }
  }
}

private struct ModelExhausted: Error {}

// The story's model: a session's own script of replies, else the shared one,
// given in order.
final class Model: Sendable {
  private let scripts = Mutex<[SessionID?: [Reply]]>([:])

  func script(_ replies: [Reply], for session: SessionID? = nil) { scripts.withLock { $0[session] = replies } }

  func next(for session: SessionID) throws -> Reply {
    try scripts.withLock { scripts in
      let key = scripts[session] == nil ? nil : session
      guard var replies = scripts[key], !replies.isEmpty else { throw ModelExhausted() }
      defer { scripts[key] = replies }
      return replies.removeFirst()
    }
  }
}

final class Story: Sendable {
  let space: Space
  let store: SessionStore
  let tokens: ExecTokens
  let execution: SessionExecution
  let hub: MachineHub
  let handler: UpgradingHandler
  let api: FetchClient
  let model = Model()
  private let jobs: AsyncStream<@Sendable () async -> Void>
  private let host: AsyncStream<@Sendable () async -> Void>.Continuation
  private let scratch = Mutex<[ScratchFolder]>([])
  init() async throws {
    let space = try Space.inMemory()
    self.space = space
    store = space.sessions
    _ = try await space.fs(.settings).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
    tokens = try await testTokens(space: space, spaceURL: "http://space")
    let hub = MachineHub(space: space, tokens: tokens)
    self.hub = hub
    let usage = UsageBoard()
    let catalog = groupCatalog(space: space, access: InferenceAccess())
    let owner = Hub(
      space: space, machines: machineSeam(hub: hub),
      resolveModelExecutor: modelExecutorResolver(space: space),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
    )
    // The worker reaches main's API, which is built after it, through `connection`, bound once both exist.
    let connection = MainConnection()
    let model = model
    execution = SessionExecution(
      connection: connection, credential: { [tokens] in try await tokens.sessionToken($0) }, space: space,
    ) { executor in
      LoopConfig(
        executeTool: { try await executor.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
        inference: { request in
          let reply = try model.next(for: request.sessionID)
          return LoopCore.InferenceReply(
            message: reply.message(request.lines),
            metadata: AssistantMessageMetadata(stopReason: .stop, usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10)),
          )
        },
        budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
      )
    }
    let runtime = SessionRuntime(execution: execution, owner: owner, tokens: tokens, connection: MainConnection())
    handler = SpaceServer.configuredHandler(space: space, hub: hub, sessions: runtime, dev: true, execTokens: tokens, listenerRoutes: machineListenerRoutes(space: space, hub: hub))
    api = ServeTesting.client(upgrading: handler)
    connection.bind(api, dial: inProcessDial(api: handler, hub: hub))
    (jobs, host) = AsyncStream.makeStream()
  }

  func script(_ replies: [Reply], for session: SessionID? = nil) { model.script(replies, for: session) }

  func machine(seeing: @escaping @Sendable (Request) -> Void = { _ in }) async throws -> (id: MachineID, folder: String) {
    let added: MachineAddOutput = try await call(.post, "/v1/machine-v2", ["name": "box"])
    let key = Curve25519.Signing.PrivateKey()
    let _: JSONValue = try await call(.post, "/v1/enroll/consume", ["token": .string(added.token), "pubkey": .string(key.pubkeyLabel)])
    let work = try ScratchFolder("story-work")
    scratch.withLock { $0.append(work) }
    let agent = try OperationAgent(machine: added.id.rawValue, kinds: fileOperationKinds() + [.init(ExecKind())], authorize: { _, _ in })
    let link = try #require(BoxLink(worker: space.worker, machine: added.id.rawValue, pubkey: key.pubkeyLabel, connection: UUID(), streams: 1024, buffers: space.machineBuffers) {
      try await self.hub.prepare($0, machine: added.id.rawValue)
    })
    let client = FetchClient { request in seeing(request); return try await agent.handler(request) }
    host.yield {
      defer { link.close() }
      await withDiscardingTaskGroup { tasks in
        tasks.addTask { await agent.run() }
        await link.run(client: client)
        tasks.cancelAll()
        await agent.shutdown()
      }
    }
    return (added.id, work.path)
  }

  func running<R: Sendable>(_ body: () async throws -> R) async throws -> R {
    defer { scratch.withLock { $0.forEach { $0.remove() } } }
    let result = try await withThrowingTaskGroup(of: Void.self) { group in
      execution.start()
      group.addTask { [execution] in await whenCancelled { await execution.shutdown() } }
      group.addTask { [jobs] in
        await withDiscardingTaskGroup { hosted in
          for await job in jobs { hosted.addTask { await job() } }
        }
      }
      let result = try await body()
      group.cancelAll()
      try await group.waitForAll()
      return result
    }
    return result
  }

  func session() async throws -> SessionID {
    try await store.createSession(
      group: .shared, title: "story", kind: .agent, createdBy: "owner",
      model: ModelSpecifier(provider: "testing", model: "test-model", effort: "high"),
    )
  }

  func say(_ text: String, to id: SessionID) async throws {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    try await store.enqueue(id, input: .message(ConversationMessage(
      id: uuid(), messageID: MessageID(uuid().uuidString.lowercased()), conversationID: ConversationID(id.rawValue),
      sender: Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: date.now, content: MessageContent(text: text),
    )))
  }

  func settled(_ id: SessionID) async throws {
    try await until("the session settles") { try await store.settledWork(id) }
  }

  func replies(_ id: SessionID) async throws -> [String] {
    try await store.testLines(id).assistantTexts
  }

  private func call<Output: Decodable>(_ method: Fetch.Method, _ path: String, _ body: JSONValue? = nil, bearer: String? = nil) async throws -> Output {
    var request = Request(url: URL(string: "http://space\(path)")!, method: method)
    if let body { request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json") }
    if let bearer { request.headers[.authorization] = "Bearer " + bearer }
    let response = try await api(request)
    let text = try await response.text()
    #expect(response.status == .ok, "\(path): \(text)")
    return try JSONDecoder().decode(Output.self, from: Data(text.utf8))
  }
}

extension [TranscriptLine] {
  var assistantTexts: [String] {
    flatMap { line -> [String] in
      guard case let .assistant(message) = line.message else { return [] }
      return message.content.compactMap { block in
        guard case let .text(text) = block else { return nil }
        return text.text
      }
    }
  }
}
