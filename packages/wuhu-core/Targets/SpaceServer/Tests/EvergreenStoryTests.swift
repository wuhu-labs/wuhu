import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import LoopCore
import MachineAgent
import MachineContract
import MainHub
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

// The evergreen story: main owns the store and serves its API; workers run
// the loops, the tools and the scripts, and reach main only through it. A
// worker can be drained while its sessions are busy: each stops at the end
// of what cannot move (an inference, a script), lets go of what the next
// worker rejoins (an exec on a machine), and goes on there with the same
// transcript. The model is scripted; the server and the machine run in
// process; nothing is faked on main's side.
@Suite(.deterministicDependencies) struct EvergreenStoryTests {
  @Test(arguments: Pairing.allCases) func aSettledSessionGoesOnWhereItLeftOff(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([say("hello from A"), say("hello from B")])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("first", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.isEmpty)

        try await story.drain(a)

        try await story.say("second", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        #expect(b.inferences.first?.assistantTexts == ["hello from A"])
        #expect(try await story.replies(session) == ["hello from A", "hello from B"])
      }
    }
  }

  // A turn with tools on both sides of the move: A writes a file and is
  // asked again with the result; the drain waits for that inference, which
  // ends in a read; B runs the read and the inference after it.
  @Test(arguments: Pairing.allCases) func aBusyTurnMovesWhenTheInferenceInFlightEnds(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let thinking = Gate()
      let story = try await Story(pairing)
      story.script([
        call("write", ["path": "/story/note.md", "content": "kept"]),
        held(thinking, call("read", ["path": "/story/note.md"])),
        say("done"),
      ])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("go", to: session)
        try await until("A is asked with the write's result") { a.inferences.count == 2 }

        let moved = story.draining(a)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        #expect(!moved.isOpen, "the drain waits for the inference in flight")
        thinking.open()
        await moved.wait()

        try await story.settled(session)
        #expect(a.inferences.count == 2 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls write", "result", "calls read", "result", "says"], "\(told)")
        #expect(try await story.failures(session).isEmpty)
        #expect(try await story.replies(session) == ["done"])
      }
    }
  }

  // The exec keeps running on the machine: A lets go of its wait at once,
  // the call stays pending, B rejoins the same exec by the call id and gets
  // its exit.
  @Test(arguments: Pairing.allCases) func anExecHandsOffAtOnceAndTheNextWorkerRejoinsIt(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let box = try await story.machine()
        story.script([
          call("exec", [
            "machine": .string(box.id.rawValue), "cwd": .string(box.folder),
            "command": "echo started; touch started; sleep 1; echo finished", "wait_seconds": 30,
          ]),
          say("done"),
        ])
        let session = try await story.session()
        try await story.say("run", to: session)
        let exec = try await story.liveExec(of: session)
        try await until("the command runs on the machine") { FileManager.default.fileExists(atPath: box.folder + "/started") }

        let clock = ContinuousClock()
        let started = clock.now
        try await story.drain(a)
        let took = clock.now - started
        let afterDrain = try await story.space.execRecord(exec)
        #expect(afterDrain?.terminal == nil, "the drain did not wait for the exec: \(took), released \(a.released), \(String(describing: afterDrain))")

        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls exec", "result", "says"], "\(told)")
        #expect(try await story.execOutputs(session) == ["started\nfinished\n"])
        let ended = try await story.space.execRecord(exec)
        #expect(ended?.terminal == .exited(code: 0) && ended?.toolCallID != nil, "the same exec ended: \(String(describing: ended))")
      }
    }
  }

  // The exec call returned `running` and the turn ended; the exec still runs
  // on the machine when A is drained. A lets go of it without a word, B
  // takes it up when the session mounts there, and its end arrives once, on B.
  @Test(arguments: Pairing.allCases) func aRunningExecGoesWithItsSession(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let box = try await story.machine()
        story.script([
          call("exec", [
            "machine": .string(box.id.rawValue), "cwd": .string(box.folder),
            "command": "echo started; touch started; while [ ! -e go ]; do sleep 0.05; done; echo finished", "wait_seconds": 1,
          ]),
          say("waiting"),
          say("done"),
        ])
        let session = try await story.session()
        try await story.say("run", to: session)
        let exec = try await story.liveExec(of: session)
        try await story.settled(session)
        #expect(try await story.replies(session) == ["waiting"])

        try await story.drain(a)
        #expect(try await story.space.execRecord(exec)?.terminal == nil, "the exec outlives the drain")
        #expect(try await a.line.runningWork(session).isEmpty, "A let go of the exec")
        try await until("B follows the exec") { try await b.line.runningWork(session) == [execHandle(exec)] }
        FileManager.default.createFile(atPath: box.folder + "/go", contents: nil)

        try await until("the end arrives and B answers it") { try await story.replies(session) == ["waiting", "done"] }
        try await story.settled(session)
        #expect(a.inferences.count == 2 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls exec", "result", "says", "hears the exec end", "says"], "\(told)")
        let notices = try await story.execEnds(session)
        #expect(notices.count == 1 && notices.first?.hasSuffix("started\nfinished\n") == true, "\(notices)")
      }
    }
  }

  // A worker that comes up while main runs takes sessions as one that was
  // there from the start does.
  @Test(arguments: Pairing.allCases) func aWorkerThatComesUpLaterTakesTheSessions(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([say("hello from A"), say("hello from B")])
      let a = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("first", to: session)
        try await story.settled(session)

        let b = try await story.worker()
        try await story.drain(a)

        try await story.say("second", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        #expect(try await story.replies(session) == ["hello from A", "hello from B"])
      }
    }
  }

  // A script runs in its worker's JavaScript runtime and cannot move: the
  // drain waits for the call to answer, then the session goes on with it.
  @Test(arguments: Pairing.allCases) func aScriptEndsHereBeforeItsSessionMoves(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([
        call("run_script", ["source": "await new Promise((go) => setTimeout(go, 500)); result('ran')", "wait_seconds": 30]),
        say("done"),
      ])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("script", to: session)
        try await until("A runs the script") { await a.scripts == 1 }

        let moved = story.draining(a)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        let stillRunning = await a.scripts == 1
        #expect(!moved.isOpen && stillRunning, "the drain waits for the script")
        await moved.wait()

        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls run_script", "result", "says"], "\(told)")
        #expect(try await story.scriptOutputs(session).first?.contains("ran") == true)
        #expect(try await story.replies(session) == ["done"])
      }
    }
  }
}

// MARK: - The mini harness

// How main reaches a worker: by calling it, or over the line the worker
// opens, each call and answer serialized.
enum Pairing: CaseIterable, Sendable {
  case direct, serialized
}

// What the model answers next, whichever worker asks; `gate` holds the
// answer until a test opens it.
private struct Reply: Sendable {
  var gate: Gate?
  var message: AssistantMessage
}

private func say(_ text: String) -> Reply {
  Reply(message: AssistantMessage(content: [.text(.init(text: text))]))
}

private func call(_ tool: String, _ arguments: JSONValue) -> Reply {
  let id = "call-" + UUID().uuidString.lowercased().prefix(8)
  return Reply(message: AssistantMessage(content: [.toolCall(ToolCall(id: id, name: tool, arguments: ToolArguments(arguments)))]))
}

private func held(_ gate: Gate, _ reply: Reply) -> Reply {
  var held = reply
  held.gate = gate
  return held
}

private struct ModelExhausted: Error {}

// The story's model: one script of replies, given in order to whichever
// worker runs the inference.
private final class Model: Sendable {
  private let replies = Mutex<[Reply]>([])

  func script(_ replies: [Reply]) { self.replies.withLock { $0 = replies } }

  func next() throws -> Reply {
    try replies.withLock {
      guard !$0.isEmpty else { throw ModelExhausted() }
      return $0.removeFirst()
    }
  }
}

// What a worker's model was asked.
private final class Asked: Sendable {
  let transcripts = Mutex<[Transcript]>([])
  let released = Mutex<[(String, Bool)]>([])
}

// One worker: its line to main, its loops, and what its model was asked.
private final class StoryWorker: Sendable {
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

private final class Story: Sendable {
  let pairing: Pairing
  let space: Space
  let store: SessionStore
  let tokens: ExecTokens
  let workers: WorkerRegistry
  let service: SessionService
  let hub: MachineHub
  let handler: UpgradingHandler
  let api: FetchClient
  let model = Model()
  // What `running` hosts besides the service: the machine side of each
  // WebSocket main accepted, and each machine agent.
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
    let usage = UsageBoard()
    let catalog = groupCatalog(space: space, access: InferenceAccess())
    let owner = Hub(
      space: space, machines: machineSeam(hub: hub),
      resolveModelExecutor: modelExecutorResolver(space: space),
      resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
      prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
    )
    workers = WorkerRegistry(tokens: tokens)
    service = SessionService(sessions: store, worker: workers)
    let runtime = SessionRuntime(
      space: space, service: service, workers: workers, attempts: AttemptHub(), owner: owner, tokens: tokens, connection: MainConnection(),
    )
    handler = SpaceServer.configuredHandler(space: space, hub: hub, sessions: runtime, dev: true, execTokens: tokens)
    api = ServeTesting.client(upgrading: handler)
    (jobs, host) = AsyncStream.makeStream()
  }

  func script(_ replies: [Reply]) { model.script(replies) }

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
          let reply = try model.next()
          if let gate = reply.gate { await gate.wait() }
          return LoopCore.InferenceReply(
            message: reply.message,
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

  // A machine: a real agent in this process, enrolled and dialling main
  // through its API, running `sh` in a folder of its own.
  func machine() async throws -> (id: MachineID, folder: String) {
    let added: MachineAddOutput = try await call(.post, "/v1/machine", ["name": "box"])
    let key = Curve25519.Signing.PrivateKey()
    let _: JSONValue = try await call(.post, "/v1/enroll/consume", ["token": .string(added.token), "pubkey": .string(key.pubkeyLabel)])
    let challenge = (try await call(.get, "/v1/machine/challenge") as MachineChallengeOutput).challenge
    let signature = try key.signature(for: MachineConnect.signingPayload(challenge: challenge))
    var headers = RequestHeaders()
    headers.set("connection", "Upgrade")
    headers.set("upgrade", "websocket")
    headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    headers.set("sec-websocket-version", "13")
    headers.set(MachineConnect.pubkeyHeader, key.pubkeyLabel)
    headers.set(MachineConnect.challengeHeader, challenge)
    headers.set(MachineConnect.signatureHeader, signature.base64EncodedString())
    headers.set(MachineConnect.capabilitiesHeader, MachineConnect.groupSecrets)
    guard case let .webSocket(socket, serve) = try await ServeTesting.upgrade(handler, Request(url: URL(string: "http://space/v1/machine/connect")!, headers: headers)) else {
      throw UnexpectedResponse(status: .badRequest)
    }
    host.yield(serve)
    let state = try ScratchFolder("evergreen-agent"), work = try ScratchFolder("evergreen-work")
    scratch.withLock { $0 += [state, work] }
    let agent = makeAgent(state: state)
    let dialer = AgentDialer()
    dialer.offer(socket)
    host.yield { await agent.run(dial: dialer.dial) }
    try await until("the machine attaches") { await hub.attachedMachines().contains(added.id) }
    return (added.id, work.path)
  }

  func running<R: Sendable>(_ body: () async throws -> R) async throws -> R {
    defer { scratch.withLock { $0.forEach { $0.remove() } } }
    let result = try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [service] in try await service.start() }
      group.addTask { [hub] in await hub.run() }
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

private extension Transcript {
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

  var results: [ToolResultPayload] {
    items.compactMap { if case let .toolResult(result) = $0 { result.payload } else { nil } }
  }
}
