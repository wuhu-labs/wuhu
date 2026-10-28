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
import TaskLifetime
import Testing
import WuhuAI

// MARK: - The mini harness

// How main reaches a worker: by calling it, or over the line the worker
// opens, each call and answer serialized.
enum Pairing: CaseIterable, Sendable {
  case direct, serialized
}

// What the model answers next, made from the transcript it is asked with;
// `gate` holds the answer until a test opens it.
struct Reply: Sendable {
  var gate: Gate?
  var message: @Sendable (Transcript) -> AssistantMessage

  static func say(_ text: String) -> Reply {
    Reply { _ in AssistantMessage(content: [.text(.init(text: text))]) }
  }

  static func call(_ tool: String, _ arguments: JSONValue) -> Reply {
    .call(tool) { _ in arguments }
  }

  static func call(_ tool: String, _ arguments: @escaping @Sendable (Transcript) -> JSONValue) -> Reply {
    let id = "call-" + UUID().uuidString.lowercased().prefix(8)
    return Reply { AssistantMessage(content: [.toolCall(ToolCall(id: id, name: tool, arguments: ToolArguments(arguments($0))))]) }
  }

  static func held(_ gate: Gate, _ reply: Reply) -> Reply {
    var held = reply
    held.gate = gate
    return held
  }
}

private struct ModelExhausted: Error {}

// The story's model: a session's own script of replies, else the shared one,
// given in order to whichever worker runs the inference.
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

// What a worker's model was asked.
final class Asked: Sendable {
  let transcripts = Mutex<[Transcript]>([])
  let released = Mutex<[(String, Bool)]>([])
}

// One worker: its line to main, its loops, and what its model was asked.
final class StoryWorker: Sendable {
  let id: WorkerID
  let line: SessionExecution
  private let asked: Asked

  init(id: WorkerID, line: SessionExecution, asked: Asked) {
    self.id = id
    self.line = line
    self.asked = asked
  }

  var inferences: [Transcript] { asked.transcripts.withLock { $0 } }
  var released: [(String, Bool)] { asked.released.withLock { $0 } }
  var scripts: Int { get async { await line.activity().scripts.count } }
}

final class Story: Sendable {
  let pairing: Pairing
  let space: Space
  let store: SessionStore
  let tokens: ExecTokens
  let workers: WorkerRegistry
  let service: SessionService
  let hub: MachineHub
  let machineV2Hub: MachineV2Hub
  let handler: UpgradingHandler
  let api: FetchClient
  let model = Model()
  private let jobs: AsyncStream<@Sendable () async -> Void>
  private let host: AsyncStream<@Sendable () async -> Void>.Continuation
  private let scratch = Mutex<[ScratchFolder]>([])
  // Each serialized worker's line, open until the story ends.
  private let lines = TaskScope()

  init(_ pairing: Pairing) async throws {
    self.pairing = pairing
    let space = try Space.inMemory()
    self.space = space
    store = space.sessions
    _ = try await space.fs(.settings).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
    tokens = ExecTokens(spaceURL: "http://space")
    let hub = MachineHub(space: space, tokens: tokens)
    self.hub = hub
    let machineV2Hub = MachineV2Hub(space: space)
    self.machineV2Hub = machineV2Hub
    let usage = UsageBoard()
    let catalog = groupCatalog(space: space, access: InferenceAccess())
    let owner = Hub(
      space: space, machines: machineSeam(hub: hub),
      resolveModelExecutor: modelExecutorResolver(space: space),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
    )
    workers = WorkerRegistry(tokens: tokens, machines: nil)
    service = SessionService(sessions: store, worker: workers)
    let runtime = SessionRuntime(
      space: space, service: service, workers: workers, attempts: AttemptHub(), owner: owner, tokens: tokens, connection: MainConnection(),
    )
    handler = SpaceServer.configuredHandler(space: space, hub: hub, sessions: runtime, dev: true, execTokens: tokens, machineV2Hub: machineV2Hub)
    api = ServeTesting.client(upgrading: handler)
    (jobs, host) = AsyncStream.makeStream()
  }

  func script(_ replies: [Reply], for session: SessionID? = nil) { model.script(replies, for: session) }

  // A worker comes up: its own line to main's API with the credential main
  // minted for it, its loops and tools behind that line, and the story's
  // model.
  func worker() async throws -> StoryWorker {
    let credential = workers.mint()
    let connection = MainConnection()
    connection.bind(api, dial: inProcessDial(api: handler, hub: hub))
    let asked = Asked()
    let model = model
    let execution = await SessionExecution(
      main: MainClient(connection: connection, credential: { credential.token }),
      connection: connection, credential: { [tokens] in tokens.sessionToken($0) },
    ) { executor in
      LoopConfig(
        executeTool: { try await executor.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
        inference: { request in
          asked.transcripts.withLock { $0.append(request.transcript) }
          let reply = try model.next(for: request.sessionID)
          if let gate = reply.gate { await gate.wait() }
          return LoopCore.InferenceReply(
            message: reply.message(request.transcript),
            metadata: AssistantMessageMetadata(stopReason: .stop, usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10)),
          )
        },
        compact: { _, _ in CompactionResult(summary: "compacted") },
        budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
        releaseTool: { invocation in
          let released = await executor.release(session: invocation.sessionID, callID: ToolCallID(invocation.call.id))
          asked.released.withLock { $0.append((invocation.call.name, released)) }
          return released
        },
      )
    }
    switch pairing {
    case .direct:
      workers.announce(credential.id, endpoint: execution)
    case .serialized:
      try lines.run("worker line") { try? await connection.serveLine(execution, credential: credential.token) }
      try await until("the worker opens its line") { [workers] in workers.workers.contains(credential.id) }
    }
    return StoryWorker(id: credential.id, line: execution, asked: asked)
  }

  func machine(seeing: @escaping @Sendable (Request) -> Void = { _ in }) async throws -> (id: MachineID, folder: String) {
    let added: MachineAddOutput = try await call(.post, "/v1/machine-v2", ["name": "box"])
    let key = Curve25519.Signing.PrivateKey()
    let _: JSONValue = try await call(.post, "/v1/enroll/consume", ["token": .string(added.token), "pubkey": .string(key.pubkeyLabel)])
    let work = try ScratchFolder("evergreen-work")
    scratch.withLock { $0.append(work) }
    let agent = try OperationAgent(machine: added.id.rawValue, kinds: fileOperationKinds() + [.init(ExecKind())], authorize: { _, _ in })
    let service = MachineV2Service(
      space: space, hub: machineV2Hub, key: SymmetricKey(size: .bits256), failure: nil,
      fetch: { _ in FetchClient { request in seeing(request); return try await agent.handler(request) } },
    )
    await hub.configureV2(service)
    host.yield { await agent.run() }
    host.yield {
      do { try await service.run() }
      catch is CancellationError {} catch { Issue.record("machine service failed: \(error)") }
      await agent.shutdown()
      await service.shutdown()
    }
    return (added.id, work.path)
  }

  func running<R: Sendable>(_ body: () async throws -> R) async throws -> R {
    defer { scratch.withLock { $0.forEach { $0.remove() } } }
    let result = try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [service] in try await service.start() }
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
    lines.cancel()
    await lines.close()
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
    _ = try await service.enqueue(item: .message(ConversationMessage(
      id: uuid(), messageID: MessageID(uuid().uuidString.lowercased()), conversationID: ConversationID(id.rawValue),
      sender: Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: date.now, content: MessageContent(text: text),
    )), to: id)
  }

  func settled(_ id: SessionID) async throws {
    try await until("the session settles") { try await store.record(id).work == .noWork }
  }

  func drain(_ worker: StoryWorker) async throws {
    try await workers.drain(worker.id)
  }

  // The drain started in the background: the gate opens when it returns.
  func draining(_ worker: StoryWorker) -> Gate {
    let done = Gate()
    Task {
      do { try await drain(worker) } catch { Issue.record("drain failed: \(error)") }
      done.open()
    }
    return done
  }

  func liveExec(of session: SessionID) async throws -> ExecID {
    var live: [ExecRecord] = []
    try await until("the exec starts") {
      live = try await space.liveToolExecs(caller: session.rawValue)
      return !live.isEmpty
    }
    return live[0].id
  }

  func replies(_ id: SessionID) async throws -> [String] {
    try await store.transcript(id).assistantTexts
  }

  func transcript(_ id: SessionID) async throws -> [String] {
    try await store.transcript(id).story
  }

  func execOutputs(_ id: SessionID) async throws -> [String] {
    try await store.transcript(id).results.compactMap { if case let .exec(result) = $0 { result.output } else { nil } }
  }

  func scriptOutputs(_ id: SessionID) async throws -> [String] {
    try await store.transcript(id).results.compactMap { if case let .script(result) = $0 { result.output } else { nil } }
  }

  func execEnds(_ id: SessionID) async throws -> [String] {
    try await store.transcript(id).items.compactMap { if case let .notification(notice) = $0, notice.kind == .exec { notice.content.text } else { nil } }
  }

  func failures(_ id: SessionID) async throws -> [ToolFailure] {
    try await store.transcript(id).results.compactMap { if case let .failure(failure) = $0 { failure } else { nil } }
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

extension Transcript {
  var assistantTexts: [String] {
    items.flatMap { item -> [String] in
      guard case let .assistant(entry) = item else { return [] }
      return entry.content.compactMap { block in
        guard case let .text(text) = block else { return nil }
        return text.text
      }
    }
  }

  // The transcript as a story: what the session heard, called, got and said.
  var story: [String] {
    items.compactMap { item in
      switch item {
      case .message: "hears"
      case let .assistant(entry): entry.toolCalls.isEmpty ? "says" : "calls " + entry.toolCalls.map(\.name).joined(separator: " ")
      case .toolResult: "result"
      case let .notification(notice) where notice.kind == .exec: "hears the exec end"
      default: nil
      }
    }
  }

  fileprivate var results: [ToolResultPayload] {
    items.compactMap { if case let .toolResult(result) = $0 { result.payload } else { nil } }
  }
}
