import Dependencies
import Fetch
import Logging
import SessionDomain
import SpaceCore
import Synchronization

// Executions live in this process only: a restarted server has none. The
// machine processes a script started outlive it only by a crash; at boot `run`
// tells each owner its script is gone, and the hub reaps the processes.
public final class Scripts: Sendable {
  let owner: any ScriptOwnerClient
  let lifecycle: ScriptLifecycle?
  let discovery = Mutex(ScriptDiscoveryConfiguration())
  private let launches: AsyncStream<ScriptExecution>
  private let launch: AsyncStream<ScriptExecution>.Continuation
  private let running = Mutex<[String: ScriptExecution]>([:])

  public init(owner: any ScriptOwnerClient, lifecycle: ScriptLifecycle? = nil) {
    self.lifecycle = lifecycle
    self.owner = owner
    (launches, launch) = AsyncStream.makeStream()
  }

  public func run(announceRestart: Bool = true) async {
    if announceRestart { await self.announceRestart() }
    await withDiscardingTaskGroup { group in
      for await execution in launches {
        group.addTask {
          await execution.run(owner: self.owner, lifecycle: self.lifecycle, registered: true)
          _ = self.running.withLock { $0.removeValue(forKey: execution.id) }
        }
      }
    }
  }

  public func announceRestart() async { await Self.announceRestart(owner: owner) }

  public static func announceRestart(owner: any ScriptOwnerClient) async {
    let ownerClient = owner
    let owners: [ScriptExecOwner]
    do {
      owners = try await owner.takeScriptExecOwners()
    } catch {
      Logger(label: "wuhu.run-script").warning("could not read the scripts a restart killed: \(error)")
      return
    }
    await announceRestart(owner: ownerClient, owners: owners)
  }

  public static func announceRestart(owner ownerClient: any ScriptOwnerClient, owners: [ScriptExecOwner]) async {
    for owner in owners {
      var text = "script \(owner.script) was killed by a server restart"
      if !owner.live.isEmpty {
        let ids = owner.live.map(\.rawValue).joined(separator: ", ")
        text += "; the machine processes it left running (\(ids)) get killed about a minute after the restart, or when their machine reconnects if it is away then"
      }
      await notify(ownerClient, SessionID(rawValue: owner.session), script: owner.script, text)
    }
  }

  func start(_ source: String, session: SessionID, lifetime: Duration, tools: ToolExecutor) async throws -> ScriptExecution {
    @Dependency(\.uuid) var uuid
    let id = String(uuid().uuidString.lowercased().prefix(8))
    let execution = ScriptExecution(
      id: id,
      session: session,
      source: source,
      lifetime: lifetime,
      secrets: ScriptSecrets(owner: owner, session: session),
      tools: tools,
      machines: owner.scriptMachines(for: session),
    )
    try await lifecycle?.started(session, id)
    do { try Task.checkCancellation() }
    catch { await lifecycle?.ended(session, id); throw error }
    running.withLock { $0[id] = execution }
    launch.yield(execution)
    return execution
  }

  func execution(_ id: String, of session: SessionID) -> ScriptExecution? {
    running.withLock { $0[id] }.flatMap { $0.session == session ? $0 : nil }
  }

  /// Sessions with a run_script execution running here; handler firings
  /// are not counted.
  var runningSessions: Set<SessionID> {
    Set(running.withLock { $0.values.map(\.session) })
  }

  /// Asks every run_script execution of `session` to stop, as archive does
  /// on a worker, without waiting: a script may be the one archiving its own
  /// session, and each ends within the stop grace regardless.
  public func stopScripts(of session: SessionID) {
    for execution in running.withLock({ $0.values.filter { $0.session == session } }) {
      execution.requestStop()
    }
  }

  let handlerInventory = Mutex<[String: SessionID]>([:])
  public var inventory: [String: SessionID] {
    running.withLock { $0.mapValues(\.session) }.merging(handlerInventory.withLock { $0 }) { _, handler in handler }
  }

  public func stop(_ id: String, session: SessionID) async throws -> ToolResultPayload {
    guard let execution = execution(id, of: session) else {
      throw ToolProblem("stop_script: you have no running script \(id)")
    }
    let output = switch await execution.stop() {
    case let .killed(stop): "script \(execution.id) was killed: \(stop.killReason)"
    case .released, .failed: "script \(execution.id) stopped"
    }
    return .script(.init(output: output))
  }

  var isIdle: Bool {
    running.withLock { $0.isEmpty }
  }
}

struct RunScriptArguments: Decodable {
  var source: String
  var timeoutSeconds: Double?
  var onTimeout: ScriptTimeoutAction?
  var maxLifetimeSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case source
    case timeoutSeconds = "timeout_seconds"
    case onTimeout = "on_timeout"
    case maxLifetimeSeconds = "max_lifetime_seconds"
  }
}

struct StopScriptArguments: Decodable {
  var id: String
}

extension ToolExecutor {
  func runScript(_ session: SessionID, _ arguments: RunScriptArguments) async throws -> ToolResultPayload {
    guard let scripts else { throw ToolProblem("run_script is not available here") }
    let timeout = min(arguments.timeoutSeconds ?? 60, scriptSecondsCeiling)
    let lifetime = min(arguments.maxLifetimeSeconds ?? 3600, scriptSecondsCeiling)
    guard timeout > 0, lifetime > 0 else {
      throw ToolProblem("run_script: timeout_seconds and max_lifetime_seconds must be positive")
    }
    let execution = try await scripts.start(arguments.source, session: session, lifetime: .seconds(lifetime), tools: self)
    switch try await execution.answer(within: .seconds(timeout), onTimeout: arguments.onTimeout ?? .detach) {
    case let .result(text):
      let note = "\n\n[script \(execution.id): any update() after this arrives as a message; stop_script ends it while it runs.]"
      return .script(.init(output: text + note))
    case .detached:
      return .script(.init(output: """
      script \(execution.id) has not called result() within \(seconds(.seconds(timeout))) s and keeps running; \
      its result arrives as a message. stop_script ends it.
      """))
    case let .failure(message):
      return .failure(.init(message: message))
    }
  }

  func stopScript(_ session: SessionID, _ arguments: StopScriptArguments) async throws -> ToolResultPayload {
    if let scripts, scripts.execution(arguments.id, of: session) != nil { return try await scripts.stop(arguments.id, session: session) }
    if let stopScript = routedScriptStop { return try await stopScript(session, arguments.id) }
    guard let scripts else { throw ToolProblem("stop_script is not available here") }
    return try await scripts.stop(arguments.id, session: session)
  }
}

public struct ScriptIdentityUnavailable: Error, Sendable {
  public let message: String
  public let code: String

  public init(message: String, code: String = "fetchIdentityUnavailable") {
    self.message = message
    self.code = code
  }
}
