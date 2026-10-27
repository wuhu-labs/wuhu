import Dependencies
import enum JSONValue.JSONValue
import Logging
import protocol MainHub.Main
import struct MainHub.ScriptError
import func MainHub.scriptHandle
import struct MainHub.ScriptHandlerResult
import struct MainHub.ScriptRunID
import func MainHub.seconds
import enum MainHub.WaitCut
import OrderedCollections
import QuickJSKit
import ServerTelemetry
import SessionDomain
import struct SpaceClient.SpaceClient
import enum SpaceContract.ScriptOutput
import SpaceCore
import Synchronization
import TaskLifetime

let scriptStopGrace: Duration = .seconds(5)
// How long a cancelled run_script call waits for its script to end.
let scriptWindDown: Duration = .seconds(10)
// The longest wait a script can ask for, in seconds: wait_seconds,
// sleep(), an AbortSignal timeout. Longer than any script runs, and far inside what
// Duration and a clock's sleep can hold; past those, the server trapped.
let scriptSecondsCeiling = 1e9
let scriptConsoleBytes = 16 * 1024
let scriptEngineMemoryBytes = 256 << 20

enum ScriptStop: Sendable, Equatable {
  case requested
  case lifetime(Duration)
  case cancelled

  var abortMessage: String {
    switch self {
    case .requested: "stopped by cancel"
    case let .lifetime(limit): "max lifetime of \(seconds(limit)) s reached"
    case .cancelled: "the run_script call was cancelled"
    }
  }

  var killReason: String {
    switch self {
    case .requested: "it ignored the cancel for \(seconds(scriptStopGrace)) s"
    case let .lifetime(limit): "it reached its max lifetime of \(seconds(limit)) s"
    case .cancelled: "the run_script call was cancelled"
    }
  }
}

enum ScriptEnding: Sendable, Equatable {
  case released
  case failed(String)
  case killed(ScriptStop)
}

enum ScriptKind: Sendable {
  /// run_script: the call takes the answer until it detaches, the session's
  /// inbox the rest.
  case call
  /// `wuhu script`: everything goes to its caller.
  case command(@Sendable (ScriptPost) -> Void)
  case handler(ScriptHandlerContext)
}

/// What a running script says, in order; its caller hears the end separately.
enum ScriptPost: Sendable {
  case update(String)
  case result(String)
  case failure(String)

  var output: ScriptOutput {
    switch self {
    case let .update(text): .update(text: text)
    case let .result(text): .result(text: text)
    case let .failure(message): .failure(message: message)
    }
  }
}

enum ScriptAnswer: Sendable, Equatable {
  case result(String)
  case failure(String)
  case detached(WaitCut)
}

final class ScriptExecution: Sendable {
  private enum Control {
    case abort(ScriptStop)
    case kill(ScriptStop)
  }

  private enum Waiter {
    case pending(AsyncStream<ScriptAnswer>.Continuation?)
    case detached
    case taken
  }

  private enum Delivery {
    case answer(AsyncStream<ScriptAnswer>.Continuation, ScriptAnswer)
    case post(ScriptPost)
    case ended([AsyncStream<ScriptEnding>.Continuation], ScriptEnding)
    case finishPost
  }

  private struct State {
    var waiter: Waiter
    var answer: ScriptAnswer?
    var resulted = false
    var stop: ScriptStop?
    var killed: ScriptStop?
    var ending: ScriptEnding?
    var endWaiters: [AsyncStream<ScriptEnding>.Continuation] = []
    var started = false
    var killRequested: ScriptStop?
    var windDowns: [WindDown] = []
    var console = ScriptConsole()
    var deliveries: [Delivery] = []
    var delivering = false
  }

  let id: String
  let session: SessionID
  let source: String
  let lifetime: Duration
  /// Main's API as the session: what the bindings touch the space through.
  let client: SpaceClient
  let secrets: ScriptSecrets
  let tools: ToolExecutor
  let kind: ScriptKind
  let arguments: [String]
  let buffers = Mutex(ScriptBuffers())
  let processes = ScriptProcesses()
  private let traceContext = ServerTracing.enabled ? ServerTracing.context : nil
  private let interrupter = JSEngine.Interrupter()
  private let state: Mutex<State>
  private let controls: AsyncStream<Control>
  private let control: AsyncStream<Control>.Continuation
  private let aborts: AsyncStream<String>
  private let abort: AsyncStream<String>.Continuation
  private let outbox: AsyncStream<ScriptPost>
  private let post: AsyncStream<ScriptPost>.Continuation

  init(
    id: String,
    session: SessionID,
    source: String,
    lifetime: Duration,
    client: SpaceClient,
    secrets: ScriptSecrets,
    tools: ToolExecutor,
    kind: ScriptKind = .call,
    arguments: [String] = [],
  ) {
    self.id = id
    self.session = session
    self.source = source
    self.lifetime = lifetime
    self.client = client
    self.secrets = secrets
    self.tools = tools
    self.kind = kind
    self.arguments = arguments
    if case .command = kind {
      state = Mutex(State(waiter: .detached))
    } else {
      state = Mutex(State(waiter: .pending(nil)))
    }
    (controls, control) = AsyncStream.makeStream()
    (aborts, abort) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (outbox, post) = AsyncStream.makeStream()
  }

  private var handler: ScriptHandlerContext? {
    if case let .handler(context) = kind { context } else { nil }
  }

  // MARK: The caller's side

  // Once `cut` returns, the call returns and the script runs on; its result
  // arrives as a message.
  func answer(until cut: @escaping @Sendable () async -> WaitCut?) async throws -> ScriptAnswer {
    let (events, sink) = AsyncStream<ScriptAnswer>.makeStream()
    state.withLock {
      $0.waiter = .pending(sink)
      if let answer = $0.answer { $0.deliveries.append(.answer(sink, answer)) }
    }
    drain()
    return try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        guard let cut = await cut() else { return }
        sink.yield(.detached(cut))
      }
      for await event in events {
        guard case let .detached(cut) = event else {
          state.withLock { $0.waiter = .taken }
          return event
        }
        return state.withLock { state -> ScriptAnswer in
          if let answer = state.answer {
            state.waiter = .taken
            return answer
          }
          state.waiter = .detached
          return .detached(cut)
        }
      }
      kill(.cancelled)
      await windDown()
      throw CancellationError()
    }
  }

  // Waits, cancelled or not, until the script has ended and its machine
  // processes are killed, or `scriptWindDown` has passed: a host call that
  // takes no cancellation holds the script, and one that waits on this very
  // call (a script interrupting its own session) would hold it for good. A
  // script that never started has nothing to wait for.
  private func windDown() async {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    let scope = TaskScope()
    let timer = Mutex<Task<Void, Never>?>(nil)
    let ended = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
      let windDown = WindDown(waiter)
      let pending = state.withLock { state -> Bool in
        guard state.started, state.ending == nil else { return false }
        state.windDowns.append(windDown)
        return true
      }
      guard pending else { return windDown.resume(ended: true) }
      timer.withLock {
        $0 = try? scope.run("script-wind-down") {
          guard (try? await clock.sleep(for: scriptWindDown)) != nil else { return }
          windDown.resume(ended: false)
        }
      }
    }
    timer.withLock { $0 }?.cancel()
    await scope.close()
    if !ended {
      Logger(label: "wuhu.run-script").error(
        "\(scriptHandle(id)) did not end within \(seconds(scriptWindDown)) s of its call's cancellation; the call returns without it",
      )
    }
  }

  func stop() async -> ScriptEnding {
    let (ended, sink) = AsyncStream<ScriptEnding>.makeStream()
    let ending = state.withLock { state -> ScriptEnding? in
      if let ending = state.ending { return ending }
      state.endWaiters.append(sink)
      if state.stop == nil { state.stop = .requested }
      return nil
    }
    if let ending { return ending }
    control.yield(.abort(.requested))
    for await ending in ended {
      return ending
    }
    return .killed(.cancelled)
  }

  /// The end of its console so far, for the `running` return.
  var consoleTail: String {
    ToolOutput.tail(state.withLock { $0.console.text }, maxLines: 40, maxBytes: 4096).text
  }

  func requestStop() {
    let ended = state.withLock { state -> Bool in
      if state.ending != nil { return true }
      if state.stop == nil { state.stop = .requested }
      return false
    }
    if !ended { control.yield(.abort(.requested)) }
  }

  func killForCancellation() {
    kill(.cancelled)
    state.withLock { $0.killed = .cancelled }
    interrupter.interrupt()
  }

  private func kill(_ stop: ScriptStop) {
    state.withLock {
      if $0.stop == nil { $0.stop = stop }
      if $0.killRequested == nil { $0.killRequested = stop }
    }
    control.yield(.kill(stop))
  }

  // MARK: The engine's side

  /// Cancelling the task that runs it kills it: a busy script never reaches
  /// a suspension point, so only the interrupter ends it.
  func run(owner: any Main) async {
    await withTaskCancellationHandler {
      await traced(owner: owner)
    } onCancel: {
      killForCancellation()
    }
  }

  private func traced(owner: any Main) async {
    guard ServerTracing.enabled else { return await runBody(owner: owner) }
    let group = (try? await client.api(.get, "/v1/context") as ScriptContext)?.group
    await ServerTracing.$context.withValue(traceContext) {
      let span = ServerSpan(.script, session: session.rawValue, group: group)
      await ServerTracing.$context.withValue(span.context) {
        await runBody(owner: owner)
        let outcome = state.withLock { state in
          switch state.ending {
          case .released: "ok"
          case .failed: "error"
          case .killed: "cancelled"
          case nil: "error"
          }
        }
        let kind = switch kind {
        case .call: "run_script"
        case .command: "wuhu_script"
        case .handler: "handler"
        }
        span.finish([.outcome: outcome, .kind: kind, .sourceSHA256: sha256Hex(source)])
      }
    }
  }

  private func runBody(owner: any Main) async {
    let killed = state.withLock { state -> ScriptStop? in
      state.started = true
      return state.killRequested
    }
    if let killed { return finish(.killed(killed)) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.deliver(to: owner) }
      group.addTask { await self.processes.run() }
      let ending = await withTaskGroup(of: ScriptEnding?.self) { race in
        race.addTask { await self.evaluate(owner: owner) }
        race.addTask { await self.supervise() }
        let first = await race.next() ?? nil
        race.cancelAll()
        // The interrupt can end the evaluation before the supervisor returns;
        // the kill still names the ending.
        if let killed = self.state.withLock({ $0.killed }) { return ScriptEnding.killed(killed) }
        return first ?? .killed(.cancelled)
      }
      // A process lives only as long as its script.
      let minted = await processes.shutdown { [client] exec in try await killScriptExec(exec, via: client) }
      if !minted.isEmpty {
        do {
          let _: JSONValue = try await client.api(.delete, "/v1/script-execs/\(pathSegment(id))")
        } catch is CancellationError {
          // The server is shutting down: the rows stay, and the next boot
          // reaps the processes and tells the owner.
        } catch {
          Logger(label: "wuhu.run-script").warning("script \(id) could not release its machine processes: \(error)")
        }
      }
      finish(ending)
    }
  }

  private func evaluate(owner: any Main) async -> ScriptEnding {
    let streams = ScriptStreams()
    let ending = await evaluate(owner: owner, streams: streams)
    await streams.shutdown()
    return ending
  }

  private func evaluate(owner: any Main, streams: ScriptStreams) async -> ScriptEnding {
    let engine = JSEngine(limits: .init(memoryBytes: scriptEngineMemoryBytes), interrupter: interrupter)
    ScriptBindings(execution: self, client: client, secrets: secrets).install(in: engine)
    ScriptFiles(client: client, execution: self).install(in: engine)
    ScriptSpace(execution: self, client: client, streams: streams).install(in: engine)
    ScriptDiscovery(client: client).install(in: engine)
    ScriptMachineBindings(execution: self, tools: tools).install(in: engine)
    do {
      try engine.defineModule("wuhu:space-core", source: spaceCoreModule)
      try engine.defineModule("wuhu:space", source: spaceModule + spaceFilesModule)
      try engine.defineModule("wuhu:secret", source: secretModule)
      try ScriptAI(session: session, tools: tools).install(in: engine)
      try ScriptSessions(session: session, tools: tools).install(in: engine)
      try engine.execute(scriptPrelude, name: "<prelude>")
      if let handler { try handler.install(in: engine) }
      try engine.defineModule("wuhu:machine", source: machineModule)
      let modules = scriptModules(client: client, snapshot: try await ScriptModuleSnapshot.load(client), typedErrors: handler != nil)
      var meta: OrderedDictionary<String, JSONValue> = ["session": .string(session.rawValue)]
      if case .command = kind { meta["args"] = .array(arguments.map(JSONValue.string)) }
      try await engine.run(module: source, name: "script", meta: meta, loader: modules)
      return .released
    } catch let JSError.exception(message, stack, _) {
      let trace = (stack ?? "").split(separator: "\n").map(String.init)
      return .failed(secrets.mask(([message] + trace).joined(separator: "\n")))
    } catch {
      return .failed(secrets.mask("\(error)"))
    }
  }

  private func supervise() async -> ScriptEnding? {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    let control = control
    return await withTaskGroup(of: Void.self) { timers in
      defer { timers.cancelAll() }
      timers.addTask { [lifetime] in
        guard (try? await clock.sleep(for: lifetime)) != nil else { return }
        self.state.withLock { if $0.stop == nil { $0.stop = .lifetime(lifetime) } }
        control.yield(self.handler == nil ? .abort(.lifetime(lifetime)) : .kill(.lifetime(lifetime)))
      }
      var aborted = false
      for await event in controls {
        switch event {
        case let .abort(stop):
          guard !aborted else { continue }
          aborted = true
          abort.yield(stop.abortMessage)
          timers.addTask {
            guard (try? await clock.sleep(for: scriptStopGrace)) != nil else { return }
            control.yield(.kill(stop))
          }
        case let .kill(stop):
          state.withLock { $0.killed = stop }
          interrupter.interrupt()
          return .killed(stop)
        }
      }
      return nil
    }
  }

  private func deliver(to owner: any Main) async {
    for await output in outbox {
      if case let .command(say) = kind {
        say(output)
        continue
      }
      let text: String
      switch output {
      case let .update(update), let .failure(update): text = update
      case let .result(result): text = "result of \(scriptHandle(id)):\n" + result
      }
      await notify(owner, session, script: id, text)
    }
  }

  // MARK: Host functions

  func handlerResult() throws -> ScriptHandlerResult {
    try Task.checkCancellation()
    let ending = state.withLock { $0.ending }
    guard ending == .released, let handler else {
      throw ScriptError(ending?.afterResult ?? "handler did not finish")
    }
    let result = try handler.result()
    return ScriptHandlerResult(stateJSON: result.stateJSON, wakes: result.wakes.map(secrets.mask))
  }

  func nextAbort() async throws -> String {
    for await reason in aborts {
      return reason
    }
    throw CancellationError()
  }

  func recordResult(_ text: String) throws {
    guard handler == nil else { throw ScriptError("handlers return state; result() is only for run_script") }
    state.withLock { state in
      state.resulted = true
      produce(.result(text), in: &state)
    }
    drain()
  }

  func recordUpdate(_ text: String) throws {
    guard handler == nil else { throw ScriptError("handlers use wake(text); update() is only for run_script") }
    state.withLock { $0.deliveries.append(.post(.update(text))) }
    drain()
  }

  func log(_ level: String, _ text: String) {
    state.withLock { $0.console.append(level, text) }
  }

  private func produce(_ answer: ScriptAnswer, in state: inout State) {
    switch state.waiter {
    case let .pending(sink):
      state.answer = answer
      if let sink { state.deliveries.append(.answer(sink, answer)) }
    case .detached:
      state.waiter = .taken
      switch answer {
      case let .result(text):
        state.deliveries.append(.post(.result(text)))
      case let .failure(message):
        state.deliveries.append(.post(.failure(message)))
      case .detached:
        break
      }
    case .taken:
      break
    }
  }

  private func finish(_ ending: ScriptEnding) {
    let windDowns = state.withLock { state -> [WindDown] in
      state.ending = ending
      let tail = state.console.rendered
      let stopped = state.stop == .requested
      if handler != nil {
        // Handler failures belong to the durable slot, not run_script delivery.
      } else if !state.resulted {
        let awaited = if case .pending = state.waiter { true } else { false }
        if awaited || !stopped {
          produce(.failure("\(scriptHandle(id)) " + ending.withoutResult + tail), in: &state)
        }
      } else if ending != .released, !stopped {
        state.deliveries.append(.post(.failure("\(scriptHandle(id)) failed after its result: " + ending.afterResult + tail)))
      }
      state.deliveries.append(.ended(state.endWaiters, ending))
      state.endWaiters = []
      state.deliveries.append(.finishPost)
      let windDowns = state.windDowns
      state.windDowns = []
      return windDowns
    }
    drain()
    for windDown in windDowns {
      windDown.resume(ended: true)
    }
  }

  // Claim one drainer so concurrent state transitions cannot overtake a result or finish.
  private func drain() {
    let claimed = state.withLock { state in
      guard !state.delivering else { return false }
      state.delivering = true
      return true
    }
    guard claimed else { return }
    while true {
      let deliveries = state.withLock { state -> [Delivery] in
        guard !state.deliveries.isEmpty else {
          state.delivering = false
          return []
        }
        defer { state.deliveries.removeAll(keepingCapacity: true) }
        return state.deliveries
      }
      guard !deliveries.isEmpty else { return }
      for delivery in deliveries {
        switch delivery {
        case let .answer(sink, answer):
          sink.yield(answer)
        case let .post(text):
          post.yield(text)
        case let .ended(waiters, ending):
          for waiter in waiters {
            waiter.yield(ending)
            waiter.finish()
          }
        case .finishPost:
          post.finish()
        }
      }
    }
  }
}

extension ScriptEnding {
  fileprivate var withoutResult: String {
    switch self {
    case .released: "finished without calling result()"
    case let .failed(message): "threw before calling result(): \(message)"
    case let .killed(stop): "was killed: \(stop.killReason)"
    }
  }

  fileprivate var afterResult: String {
    switch self {
    case .released: ""
    case let .failed(message): message
    case let .killed(stop): "it was killed: \(stop.killReason)"
    }
  }
}

struct ScriptConsole {
  private var lines: [String] = []
  private var bytes = 0

  mutating func append(_ level: String, _ text: String) {
    let line = level == "log" ? text : "\(level): \(text)"
    lines.append(line)
    bytes += line.utf8.count
    while bytes > scriptConsoleBytes, lines.count > 1 {
      bytes -= lines.removeFirst().utf8.count
    }
  }

  var rendered: String {
    lines.isEmpty ? "" : "\n\nconsole:\n" + text
  }

  var text: String { lines.joined(separator: "\n") }
}

// Wakes `session` with a message from script `script`.
func notify(_ owner: any Main, _ session: SessionID, script: String, _ text: String) async {
  @Dependency(\.date) var date
  @Dependency(\.uuid) var uuid
  let notification = SystemNotification(
    id: uuid(),
    timestamp: date.now,
    kind: .script,
    subscriptionID: .script(script),
    content: .init(text: text),
  )
  do {
    _ = try await owner.append(session, .inputEnqueued(.notification(notification))).value(Int.self)
  } catch {
    Logger(label: "wuhu.run-script").warning("script \(script) could not reach \(session.rawValue): \(error)")
  }
}

// One wait for a script's end, answered by the end or by the time limit,
// whichever comes first.
private final class WindDown: Sendable {
  private let waiter: Mutex<CheckedContinuation<Bool, Never>?>

  init(_ waiter: CheckedContinuation<Bool, Never>) {
    self.waiter = Mutex(waiter)
  }

  func resume(ended: Bool) {
    let taken = waiter.withLock { waiter in
      let taken = waiter
      waiter = nil
      return taken
    }
    taken?.resume(returning: ended)
  }
}
