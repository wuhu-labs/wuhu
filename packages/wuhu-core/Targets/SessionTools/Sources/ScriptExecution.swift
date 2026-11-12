import Dependencies
import enum JSONValue.JSONValue
import struct MainHub.ScriptError
import func MainHub.scriptHandle
import struct MainHub.ScriptHandlerResult
import func MainHub.seconds
import OrderedCollections
import QuickJSKit
import enum ScriptWebPlatform.ScriptWebPlatform
import ServerTelemetry
import SessionDomain
import struct SpaceClient.SpaceClient
import enum SpaceContract.ScriptOutput
import SpaceCore
import Synchronization

let scriptStopGrace: Duration = .seconds(5)
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
  case job(@Sendable (ScriptRuntime.Event) -> Void)
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

final class ScriptExecution: Sendable {
  private enum Control {
    case abort(ScriptStop)
    case kill(ScriptStop)
  }

  private struct State {
    var resulted = false
    var stop: ScriptStop?
    var killed: ScriptStop?
    var ending: ScriptEnding?
    var killRequested: ScriptStop?
    var console = ScriptConsole()
    var completing = 0
    var credit: Duration = .zero
    var updates = 0
  }

  let id: String
  let actor: ScriptActor
  let source: String
  let lifetime: Duration
  /// Main's API as the session: what the bindings touch the space through.
  let client: SpaceClient
  let secrets: ScriptSecrets
  let tools: ToolExecutor
  let kind: ScriptKind
  let arguments: [String]
  let limits: ScriptLimits
  let buffers: Mutex<ScriptBuffers>
  let processes = ScriptProcesses()
  private let trace: TraceParent
  private let interrupter = JSEngine.Interrupter()
  private let state: Mutex<State>
  private let controls: AsyncStream<Control>
  private let control: AsyncStream<Control>.Continuation
  private let aborts: AsyncStream<String>
  private let abort: AsyncStream<String>.Continuation
  private let outbox: AsyncStream<ScriptPost>
  private let post: AsyncStream<ScriptPost>.Continuation
  private let credits: AsyncStream<Void>
  private let credited: AsyncStream<Void>.Continuation

  init(
    id: String,
    actor: ScriptActor,
    source: String,
    lifetime: Duration,
    client: SpaceClient,
    secrets: ScriptSecrets,
    tools: ToolExecutor,
    kind: ScriptKind,
    arguments: [String] = [],
    limits: ScriptLimits = .standard,
    trace: TraceParent = .current,
  ) {
    self.id = id
    self.actor = actor
    self.source = source
    self.lifetime = lifetime
    self.client = client
    self.secrets = secrets
    self.tools = tools
    self.kind = kind
    self.arguments = arguments
    self.limits = limits
    buffers = Mutex(ScriptBuffers(budget: limits.bufferBytes))
    self.trace = trace
    state = Mutex(State())
    (controls, control) = AsyncStream.makeStream()
    (aborts, abort) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (outbox, post) = AsyncStream.makeStream()
    (credits, credited) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  private var handler: ScriptHandlerContext? {
    if case let .handler(context) = kind { context } else { nil }
  }

  /// The end of its console so far, for the `running` return.
  var consoleTail: String {
    ToolOutput.tail(state.withLock { $0.console.text }, maxLines: 40, maxBytes: 4096).text
  }

  func killForJob() {
    let reason = state.withLock { $0.stop ?? .cancelled }
    kill(reason)
    state.withLock { $0.killed = reason }
    interrupter.interrupt()
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
  func run() async {
    await withTaskCancellationHandler {
      await traced()
    } onCancel: {
      killForCancellation()
    }
  }

  private func traced() async {
    await ServerTelemetry.traced(.script, under: trace) { span in
      await runBody()
      span.set(.scriptKind, kind.span)
      span.set(.sourceSHA256, sha256Hex(source))
      let (ending, updates) = state.withLock { ($0.ending, $0.updates) }
      span.set(.updates, updates)
      span.conclude(ending.spanOutcome)
    }
  }

  private func runBody() async {
    let killed = state.withLock { $0.killRequested }
    if let killed { return finish(.killed(killed)) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.deliver() }
      group.addTask { await self.processes.run() }
      let ending = await withTaskGroup(of: ScriptEnding?.self) { race in
        race.addTask { await self.evaluate() }
        race.addTask { await self.supervise() }
        let first = await race.next() ?? nil
        race.cancelAll()
        // The interrupt can end the evaluation before the supervisor returns;
        // the kill still names the ending.
        if let killed = self.state.withLock({ $0.killed }) { return ScriptEnding.killed(killed) }
        return first ?? .killed(.cancelled)
      }
      processes.shutdown()
      finish(ending)
    }
  }

  private func evaluate() async -> ScriptEnding {
    let streams = ScriptStreams()
    let ending = await evaluate(streams: streams)
    await streams.shutdown()
    return ending
  }

  private func evaluate(streams: ScriptStreams) async -> ScriptEnding {
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
      ScriptAI(actor: actor, tools: tools, execution: self).install(in: engine)
      ScriptSessions(actor: actor, tools: tools).install(in: engine)
      try engine.execute(scriptPrelude, name: "<prelude>")
      if let handler { try handler.install(in: engine) }
      try engine.defineModule("wuhu:host", source: hostModule)
      for module in ScriptWebPlatform.modules { try engine.defineModule(module.name, source: module.source) }
      try engine.execute("delete globalThis.__wuhu_kernel", name: "<host>")
      let modules = scriptModules(client: client, snapshot: try await ScriptModuleSnapshot.load(client), typedErrors: handler != nil)
      var meta: OrderedDictionary<String, JSONValue> = ["session": actor.session.map { .string($0.rawValue) } ?? .null]
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
    let jobClock = if case .job = kind { true } else { false }
    return await withTaskGroup(of: Void.self) { timers in
      defer { timers.cancelAll() }
      if !jobClock {
        timers.addTask { [lifetime, credits] in
          var deadline = lifetime
          var slept = Duration.zero
          var credit = credits.makeAsyncIterator()
          while true {
            guard (try? await clock.sleep(for: deadline - slept)) != nil else { return }
            slept = deadline
            let (earned, completing) = self.state.withLock { ($0.credit, $0.completing) }
            if lifetime + earned > slept { deadline = lifetime + earned; continue }
            guard completing > 0 else { break }
            guard await credit.next() != nil else { return }
          }
          self.state.withLock { if $0.stop == nil { $0.stop = .lifetime(lifetime) } }
          control.yield(self.handler == nil ? .abort(.lifetime(lifetime)) : .kill(.lifetime(lifetime)))
        }
      }
      var aborted = false
      for await event in controls {
        switch event {
        case let .abort(stop):
          guard !aborted else { continue }
          aborted = true
          abort.yield(stop.abortMessage)
          if !jobClock {
            timers.addTask {
              guard (try? await clock.sleep(for: scriptStopGrace)) != nil else { return }
              control.yield(.kill(stop))
            }
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

  private func deliver() async {
    for await output in outbox {
      switch kind {
      case let .command(say): say(output)
      case let .job(say):
        switch output {
        case let .result(text): say(.result(text))
        case let .update(text): say(.update(text))
        case .failure: preconditionFailure("job endings are delivered separately")
        }
      case .handler: preconditionFailure("handlers do not post output")
      }
    }
  }

  // MARK: Host functions

  /// Runs `work` off a handler's lifetime: what it spends waiting is added
  /// back to the handler's budget, so a slow model never kills a handler.
  func outsideLifetime<T>(_ work: () async throws -> T) async throws -> T {
    guard handler != nil else { return try await work() }
    @Dependency(\.continuousClock) var clock
    state.withLock { $0.completing += 1 }
    var outcome: Result<T, any Error> = .failure(CancellationError())
    let spent = await clock.measure {
      do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
    }
    state.withLock { $0.completing -= 1; $0.credit += spent }
    credited.yield()
    return try outcome.get()
  }

  func handlerResult() throws -> ScriptHandlerResult {
    try Task.checkCancellation()
    let ending = state.withLock { $0.ending }
    guard ending == .released, let handler else {
      throw ScriptError(ending?.afterResult ?? "handler did not finish")
    }
    let result = try handler.result()
    return ScriptHandlerResult(wakes: result.wakes.map(secrets.mask))
  }

  func nextAbort() async throws -> String {
    for await reason in aborts {
      return reason
    }
    throw CancellationError()
  }

  func recordResult(_ text: String) throws {
    guard handler == nil else { throw ScriptError("handlers return state; result() is only for run_script") }
    try state.withLock { state in
      guard !state.resulted else { throw ScriptError("result() can be called only once") }
      state.resulted = true
      post.yield(.result(text))
    }
  }

  func recordUpdate(_ text: String) throws {
    guard handler == nil else { throw ScriptError("handlers use wake(text); update() is only for run_script") }
    try state.withLock { state in
      guard state.resulted else { throw ScriptError("update() needs result() first") }
      state.updates += 1
      post.yield(.update(text))
    }
  }

  func log(_ level: String, _ text: String) {
    state.withLock { $0.console.append(level, text) }
  }

  func abortForJob(lifetime: Bool) {
    let stop: ScriptStop = lifetime ? .lifetime(self.lifetime) : .requested
    state.withLock { if $0.stop == nil { $0.stop = stop } }
    control.yield(.abort(stop))
  }

  private func finish(_ ending: ScriptEnding) {
    let (resulted, stopped, tail) = state.withLock { state in
      state.ending = ending
      return (state.resulted, state.stop == .requested, state.console.rendered)
    }
    if case .command = kind {
      if !resulted { post.yield(.failure("\(scriptHandle(id)) " + ending.withoutResult + tail)) }
      else if ending != .released, !stopped { post.yield(.failure("\(scriptHandle(id)) failed after its result: " + ending.afterResult + tail)) }
    }
    post.finish()
  }

  var termination: ScriptRuntime.End {
    state.withLock { state in
      let ending = state.ending!
      return .init(
        beforeResult: "\(scriptHandle(id)) " + ending.withoutResult + state.console.rendered,
        afterResult: ending == .released ? nil : "\(scriptHandle(id)) failed after its result: " + ending.afterResult + state.console.rendered,
      )
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

extension ScriptKind {
  fileprivate var span: ScriptSpanKind {
    switch self {
    case .job: .call
    case .command: .command
    case .handler: .handler
    }
  }
}

extension ScriptEnding? {
  fileprivate var spanOutcome: ScriptOutcome {
    switch self {
    case .released: .released
    case .failed, nil: .failed
    case .killed: .killed
    }
  }
}
