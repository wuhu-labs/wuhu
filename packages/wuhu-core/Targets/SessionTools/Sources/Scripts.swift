import Dependencies
import Fetch
import enum JSONValue.JSONValue
import Logging
import SessionDomain
import SpaceCore
import Synchronization

// Executions live in this process only: a restarted server has none. The
// machine processes a script started outlive it only by a crash; at boot `run`
// tells each owner its script is gone, and the hub reaps the processes.
public final class Scripts: Sendable {
  let owner: any Main
  let discovery = Mutex(ScriptDiscoveryConfiguration())
  private let launches: AsyncStream<ScriptExecution>
  private let launch: AsyncStream<ScriptExecution>.Continuation
  private let running = Mutex<[String: ScriptExecution]>([:])
  // Scripts that ended here, so cancel can tell "already ended" from
  // "unknown". Bounded and in-process: past either, an id reads as unknown.
  private let ended = Mutex(EndedScripts())

  public init(owner: any Main) {
    self.owner = owner
    (launches, launch) = AsyncStream.makeStream()
  }

  public func run(announceRestart: Bool = true) async {
    if announceRestart { await self.announceRestart() }
    await withDiscardingTaskGroup { group in
      for await execution in launches {
        group.addTask {
          await execution.run(owner: self.owner)
          self.ended.withLock { $0.record(execution.id, session: execution.session) }
          _ = self.running.withLock { $0.removeValue(forKey: execution.id) }
        }
      }
    }
  }

  public func announceRestart() async { await Self.announceRestart(owner: owner) }

  public static func announceRestart(owner: any Main) async {
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

  public static func announceRestart(owner ownerClient: any Main, owners: [ScriptExecOwner]) async {
    for owner in owners {
      var text = "\(scriptHandle(owner.script)) was killed by a server restart"
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
    try Task.checkCancellation()
    running.withLock { $0[id] = execution }
    launch.yield(execution)
    return execution
  }

  func execution(_ id: String, of session: SessionID) -> ScriptExecution? {
    running.withLock { $0[id] }.flatMap { $0.session == session ? $0 : nil }
  }

  /// The cancel ids of `session`'s run_script executions running here.
  public func running(of session: SessionID) -> [String] {
    running.withLock { $0.values.filter { $0.session == session }.map { scriptHandle($0.id) } }.sorted()
  }

  /// Sessions with a run_script execution running here; handler firings
  /// are not counted.
  var runningSessions: Set<SessionID> {
    Set(running.withLock { $0.values.map(\.session) })
  }

  /// Asks every run_script execution of `session` to stop, as archive does
  /// without waiting: a script may be the one archiving its own
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

  var isIdle: Bool {
    running.withLock { $0.isEmpty }
  }
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
public func scriptHandle(_ id: String) -> String { "script.\(id)" }

struct EndedScripts {
  static let capacity = 4096
  private(set) var owners: [String: SessionID] = [:]
  private var order: [String] = []

  mutating func record(_ id: String, session: SessionID) {
    if owners.updateValue(session, forKey: id) == nil { order.append(id) }
    if order.count > Self.capacity { owners.removeValue(forKey: order.removeFirst()) }
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
