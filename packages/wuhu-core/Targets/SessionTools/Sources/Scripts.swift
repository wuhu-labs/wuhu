import func MainHub.scriptHandle
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import enum JSONValue.JSONValue
import Logging
import protocol MainHub.Main
import func MainHub.runningJSON
import struct MainHub.ScriptRun
import struct MainHub.ScriptRunID
import func MainHub.seconds
import enum MainHub.ToolLifetimes
import struct MainHub.ToolProblem
import enum MainHub.WaitCut
import struct MainHub.WorkerActivity
import SessionDomain
import enum SpaceContract.ScriptOutput
import SpaceCore
import Synchronization
import TaskLifetime

public final class Scripts: Sendable {
  let owner: any Main
  // Every execution runs in here, from its start until it ends or `close`.
  private let scope = TaskScope()
  private let running = Mutex<[String: ScriptExecution]>([:])
  // Scripts that ended here, so cancel can tell "already ended" from
  // "unknown". Bounded and in-process: past either, an id reads as unknown.
  private let ended = Mutex(EndedScripts())

  public init(owner: any Main) {
    self.owner = owner
  }

  deinit { scope.cancel() }

  /// Stops every execution and waits for them to end; nothing starts after.
  public func close() async {
    scope.cancel()
    await scope.close()
  }

  func start(_ source: String, session: SessionID, lifetime: Duration, tools: ToolExecutor) async throws -> ScriptExecution {
    let id = newScriptID()
    let client = try await tools.client(session)
    let execution = ScriptExecution(
      id: id,
      actor: .session(session),
      source: source,
      lifetime: lifetime,
      client: client,
      secrets: ScriptSecrets(client: client),
      tools: tools,
    )
    try Task.checkCancellation()
    running.withLock { $0[id] = execution }
    do {
      try scope.run("script \(id)") {
        await execution.run(owner: self.owner)
        self.ended.withLock { $0.record(execution.id, session: session) }
        _ = self.running.withLock { $0.removeValue(forKey: execution.id) }
      }
    } catch {
      _ = running.withLock { $0.removeValue(forKey: id) }
      throw ToolProblem("this worker is stopping; run_script did not start")
    }
    return execution
  }

  /// Runs `script` for its caller alone: not in the session's running work,
  /// and killed when the call is cancelled or the scope closes. The run, its
  /// cleanup included, lives in the scope, so a cancelled caller still waits
  /// for its machine processes to be killed and released; `end` follows its
  /// span, as the caller's last word.
  public func run(_ script: ScriptRun, tools: ToolExecutor, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    let client = try await tools.client(script.session)
    let execution = ScriptExecution(
      id: newScriptID(),
      actor: .session(script.session),
      source: script.source,
      lifetime: .seconds(ToolLifetimes.scriptDefault),
      client: client,
      secrets: ScriptSecrets(client: client),
      tools: tools,
      kind: .command { output($0.output) },
      arguments: script.arguments,
    )
    let run: Task<Void, Never>
    do { run = try scope.run("script \(execution.id)") { await execution.run(owner: self.owner) } }
    catch { throw ToolProblem("this worker is stopping; the script did not start") }
    await withTaskCancellationHandler {
      await run.value
    } onCancel: {
      execution.killForCancellation()
    }
    try Task.checkCancellation()
    output(.end)
  }

  func execution(_ id: String, of session: SessionID) -> ScriptExecution? {
    running.withLock { $0[id] }.flatMap { $0.actor.session == session ? $0 : nil }
  }

  /// The cancel ids of `session`'s run_script executions running here.
  public func running(of session: SessionID) -> [String] {
    running.withLock { $0.values.filter { $0.actor.session == session }.map { scriptHandle($0.id) } }.sorted()
  }

  /// Asks every run_script execution of `session` to stop, as archive does
  /// without waiting: a script may be the one archiving its own
  /// session, and each ends within the stop grace regardless.
  public func stopScripts(of session: SessionID) {
    for execution in running.withLock({ $0.values.filter { $0.actor.session == session } }) {
      execution.requestStop()
    }
  }

  public var activity: WorkerActivity {
    WorkerActivity(
      scripts: running.withLock { Dictionary(uniqueKeysWithValues: $0.map { (ScriptRunID($0.key), $0.value.actor.session!) }) },
    )
  }

  public func stop(_ id: String, session: SessionID) async throws -> ToolResultPayload {
    guard let execution = execution(id, of: session) else {
      if ended.withLock({ $0.owners[id] == session }) {
        return .failure(.init(message: "\(scriptHandle(id)) has already ended", code: "alreadyEnded"))
      }
      return .failure(.init(message: "you have no script \(scriptHandle(id))", code: "notFound"))
    }
    let output = switch await execution.stop() {
    case let .killed(stop): "\(scriptHandle(execution.id)) was killed: \(stop.killReason)"
    case .released, .failed: "\(scriptHandle(execution.id)) stopped: its signal was aborted and it ended"
    }
    return .script(.init(output: output))
  }
}

private func newScriptID() -> String {
  @Dependency(\.uuid) var uuid
  return String(uuid().uuidString.lowercased().prefix(8))
}

struct RunScriptArguments: Decodable {
  var source: String
  var waitSeconds: Double?
  /// Old names, decoded only to refuse them.
  var timeoutSeconds: JSONValue?
  var onTimeout: JSONValue?
  var maxLifetimeSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case source
    case waitSeconds = "wait_seconds"
    case timeoutSeconds = "timeout_seconds"
    case onTimeout = "on_timeout"
    case maxLifetimeSeconds = "max_lifetime_seconds"
  }
}

extension ToolExecutor {
  func runScript(_ session: SessionID, _ arguments: RunScriptArguments) async throws -> ToolResultPayload {
    guard let scripts else { throw ToolProblem("run_script is not available here") }
    if arguments.timeoutSeconds != nil {
      throw ToolProblem("run_script: timeout_seconds is renamed to wait_seconds", code: "invalidArgument")
    }
    if arguments.onTimeout != nil {
      throw ToolProblem("run_script: on_timeout is gone; past wait_seconds a script always runs on, and cancel stops it", code: "invalidArgument")
    }
    let wait = min(arguments.waitSeconds ?? ToolLifetimes.waitDefault, scriptSecondsCeiling)
    let lifetime = arguments.maxLifetimeSeconds ?? ToolLifetimes.scriptDefault
    guard wait > 0 else {
      throw ToolProblem("run_script: wait_seconds must be more than 0", code: "invalidArgument")
    }
    guard lifetime > 0 else {
      throw ToolProblem("run_script: max_lifetime_seconds must be positive", code: "invalidArgument")
    }
    guard lifetime <= ToolLifetimes.ceiling else {
      throw ToolProblem("run_script: max_lifetime_seconds is at most \(seconds(.seconds(ToolLifetimes.ceiling)))", code: "invalidArgument")
    }
    let execution = try await scripts.start(arguments.source, session: session, lifetime: .seconds(lifetime), tools: self)
    let arrivals = owner.pendingArrivals(session)
    let waited = min(wait, lifetime + ToolLifetimes.lifetimeSlack)
    switch try await execution.answer(until: { await WaitCut.first(wait: waited, arrivals: arrivals) }) {
    case let .result(text):
      let note = "\n\n[\(scriptHandle(execution.id)): any update() after this arrives as a message; cancel(\"\(scriptHandle(execution.id))\") ends it while it runs.]"
      return .script(.init(output: text + note))
    case let .detached(cut):
      let handle = scriptHandle(execution.id)
      let after = switch cut {
      case .waited: "no result() within \(seconds(.seconds(wait))) s"
      case .arrival: "a message arrived, so the call gave the turn back before result()"
      }
      let note = "\(after); it keeps running, its result arrives as a message, and cancel(\"\(handle)\") stops it"
      return .script(.init(output: runningJSON(handle, tail: execution.consoleTail, note: note)))
    case let .failure(message):
      return .failure(.init(message: message))
    }
  }
}

/// How a script's id is shown and cancelled: `script.<id>`.

struct EndedScripts {
  static let capacity = 4096
  private(set) var owners: [String: SessionID] = [:]
  private var order: [String] = []

  mutating func record(_ id: String, session: SessionID) {
    if owners.updateValue(session, forKey: id) == nil { order.append(id) }
    if order.count > Self.capacity { owners.removeValue(forKey: order.removeFirst()) }
  }
}
