import Dependencies
import Logging
import QuickJSKit
import SessionDomain
import SpaceCore
import Synchronization

let scriptStopGrace: Duration = .seconds(5)
// How long a cancelled run_script call waits for its script to end.
let scriptWindDown: Duration = .seconds(10)
// The longest wait a script can ask for, in seconds: its max lifetime,
// timeout_seconds, sleep(). Longer than any script runs, and far inside what
// Duration and a clock's sleep can hold; past those, the server trapped.
let scriptSecondsCeiling = 1e9
let scriptConsoleBytes = 16 * 1024
let scriptEngineMemoryBytes = 256 << 20

enum ScriptStop: Sendable, Equatable {
  case requested
  case timeout(Duration)
  case lifetime(Duration)
  case cancelled

  var abortMessage: String {
    switch self {
    case .requested: "stopped by stop_script"
    case let .timeout(limit): "no result() within \(seconds(limit)) s"
    case let .lifetime(limit): "max lifetime of \(seconds(limit)) s reached"
    case .cancelled: "the run_script call was cancelled"
    }
  }

  var killReason: String {
    switch self {
    case .requested: "it ignored stop_script for \(seconds(scriptStopGrace)) s"
    case let .timeout(limit): "it did not call result() within \(seconds(limit)) s"
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

enum ScriptAnswer: Sendable, Equatable {
  case result(String)
  case failure(String)
  case detached
}

enum ScriptTimeoutAction: String, Decodable, Sendable {
  case detach
  case kill
}

final class ScriptExecution: Sendable {
  private enum Control {
    case abort(ScriptStop)
    case kill(ScriptStop)
  }

  private enum Waiter {
    case pending(AsyncStream<ScriptAnswer?>.Continuation?)
    case detached
    case taken
  }

  private enum Delivery {
    case answer(AsyncStream<ScriptAnswer?>.Continuation, ScriptAnswer)
    case post(String)
    case ended([AsyncStream<ScriptEnding>.Continuation], ScriptEnding)
    case finishPost
  }

  private struct State {
    var waiter = Waiter.pending(nil)
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
  let secrets: ScriptSecrets
  let tools: ToolExecutor
  let machines: ScriptMachineAccess?
  let machinesV2: ScriptMachineV2Access?
  let v2Operations = ScriptV2Operations()
  let handler: ScriptHandlerContext?
  let buffers = Mutex(ScriptBuffers())
  let processes = ScriptProcesses()
  private let interrupter = JSEngine.Interrupter()
  private let state = Mutex(State())
  private let controls: AsyncStream<Control>
  private let control: AsyncStream<Control>.Continuation
  private let aborts: AsyncStream<String>
  private let abort: AsyncStream<String>.Continuation
  private let outbox: AsyncStream<String>
  private let post: AsyncStream<String>.Continuation

  init(
    id: String,
    session: SessionID,
    source: String,
    lifetime: Duration,
    secrets: ScriptSecrets,
    tools: ToolExecutor,
    machines: ScriptMachineAccess? = nil,
    machinesV2: ScriptMachineV2Access? = nil,
    handler: ScriptHandlerContext? = nil,
  ) {
    self.id = id
    self.session = session
    self.source = source
    self.lifetime = lifetime
    self.secrets = secrets
    self.tools = tools
    self.machines = machines
    self.machinesV2 = machinesV2
    self.handler = handler
    (controls, control) = AsyncStream.makeStream()
    (aborts, abort) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (outbox, post) = AsyncStream.makeStream()
  }

  // MARK: The caller's side

  func answer(within timeout: Duration, onTimeout: ScriptTimeoutAction) async throws -> ScriptAnswer {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    let (events, sink) = AsyncStream<ScriptAnswer?>.makeStream()
    state.withLock {
      $0.waiter = .pending(sink)
      if let answer = $0.answer { $0.deliveries.append(.answer(sink, answer)) }
    }
    drain()
    return try await withThrowingTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try await clock.sleep(for: timeout)
        sink.yield(nil)
      }
      var killing = false
      for await event in events {
        if let event {
          state.withLock { $0.waiter = .taken }
          return event
        }
        guard !killing else { continue }
        let detached = state.withLock { state -> ScriptAnswer? in
          if let answer = state.answer {
            state.waiter = .taken
            return answer
          }
          guard onTimeout == .detach else { return nil }
          state.waiter = .detached
          return .detached
        }
        if let detached { return detached }
        killing = true
        kill(.timeout(timeout))
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
    let timer = Mutex<Task<Void, Never>?>(nil)
    let ended = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
      let windDown = WindDown(waiter)
      let pending = state.withLock { state -> Bool in
        guard state.started, state.ending == nil else { return false }
        state.windDowns.append(windDown)
        return true
      }
      guard pending else { return windDown.resume(ended: true) }
      // Unstructured: the waiting task is cancelled already, and a child of it
      // would be too.
      timer.withLock {
        $0 = Task {
          guard (try? await clock.sleep(for: scriptWindDown)) != nil else { return }
          windDown.resume(ended: false)
        }
      }
    }
    timer.withLock { $0 }?.cancel()
    if !ended {
      Logger(label: "wuhu.run-script").error(
        "script \(id) did not end within \(seconds(scriptWindDown)) s of its call's cancellation; the call returns without it",
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

  func cancelHandler() {
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

  func run(owner: any ScriptOwnerClient) async {
    let killed = state.withLock { state -> ScriptStop? in
      state.started = true
      return state.killRequested
    }
    if let killed { return finish(.killed(killed)) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.deliver(to: owner) }
      group.addTask { await self.processes.run() }
      group.addTask { await self.v2Operations.run() }
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
      let minted = await processes.shutdown { [machines] id in try await machines?.exec.kill(id) }
      if !minted.isEmpty {
        do {
          try await owner.releaseScriptExecs(script: id)
        } catch is CancellationError {
          // The server is shutting down: the rows stay, and the next boot
          // reaps the processes and tells the owner.
        } catch {
          Logger(label: "wuhu.run-script").warning("script \(id) could not release its machine processes: \(error)")
        }
      }
      await v2Operations.shutdown()
      finish(ending)
    }
  }

  private func evaluate(owner: any ScriptOwnerClient) async -> ScriptEnding {
    let engine = JSEngine(limits: .init(memoryBytes: scriptEngineMemoryBytes), interrupter: interrupter)
    ScriptBindings(execution: self, owner: owner, secrets: secrets).install(in: engine)
    ScriptFiles(owner: owner, execution: self).install(in: engine)
    ScriptSpace(execution: self, owner: owner).install(in: engine)
    ScriptDiscovery(execution: self, owner: owner).install(in: engine)
    ScriptMachineBindings(execution: self, owner: owner, access: machines).install(in: engine)
    ScriptMachineV2Bindings(execution: self, owner: owner, access: machinesV2).install(in: engine)
    do {
      try engine.defineModule("wuhu:space-core", source: spaceCoreModule)
      try engine.defineModule("wuhu:space", source: spaceModule + spaceFilesModule)
      try engine.defineModule("wuhu:secret", source: secretModule)
      try ScriptAI(session: session, tools: tools).install(in: engine)
      try ScriptSessions(session: session, tools: tools).install(in: engine)
      try engine.execute(scriptPrelude, name: "<prelude>")
      if let handler { try handler.install(in: engine) }
      try engine.defineModule("wuhu:machine", source: machineModule)
      let modules = scriptModules(
        owner: owner, snapshot: try await owner.moduleSnapshot(for: session), typedErrors: handler != nil,
      )
      try await engine.run(module: source, name: "script", meta: ["session": .string(session.rawValue)], loader: modules)
      return .released
    } catch let JSError.exception(message, stack) {
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

  private func deliver(to owner: any ScriptOwnerClient) async {
    for await text in outbox {
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
    var result = try handler.result()
    result.wakes = result.wakes.map(secrets.mask)
    return result
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
    state.withLock { $0.deliveries.append(.post(text)) }
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
        state.deliveries.append(.post("result of script \(id):\n" + text))
      case let .failure(message):
        state.deliveries.append(.post(message))
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
          produce(.failure("script \(id) " + ending.withoutResult + tail), in: &state)
        }
      } else if ending != .released, !stopped {
        state.deliveries.append(.post("script \(id) failed after its result: " + ending.afterResult + tail))
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

func seconds(_ duration: Duration) -> String {
  let (whole, attoseconds) = duration.components
  guard attoseconds != 0 else { return "\(whole)" }
  return "\(Double(whole) + Double(attoseconds) / 1e18)"
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
    lines.isEmpty ? "" : "\n\nconsole:\n" + lines.joined(separator: "\n")
  }
}

// Wakes `session` with a message from script `script`.
func notify(_ owner: any ScriptOwnerClient, _ session: SessionID, script: String, _ text: String) async {
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
    try await owner.notify(session: session, notification: notification)
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
