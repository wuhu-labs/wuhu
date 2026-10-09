import struct Credentials.SpaceSecretStores
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
  let space: Space
  let discovery = Mutex(ScriptDiscoveryConfiguration())
  let secrets: SpaceSecretStores?
  let machines: ScriptMachineAccess?
  let identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)?
  private let launches: AsyncStream<ScriptExecution>
  private let launch: AsyncStream<ScriptExecution>.Continuation
  private let running = Mutex<[String: ScriptExecution]>([:])

  public init(space: Space, secrets: SpaceSecretStores? = nil, machines: ScriptMachineAccess? = nil, identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil) {
    self.space = space
    self.secrets = secrets
    self.machines = machines
    self.identityFetch = identityFetch
    (launches, launch) = AsyncStream.makeStream()
  }

  public func run() async {
    await announceRestart()
    await withDiscardingTaskGroup { group in
      for await execution in launches {
        group.addTask {
          await execution.run(space: self.space)
          _ = self.running.withLock { $0.removeValue(forKey: execution.id) }
        }
      }
    }
  }

  private func announceRestart() async {
    let owners: [ScriptExecOwner]
    do {
      owners = try await space.takeScriptExecOwners()
    } catch {
      Logger(label: "wuhu.run-script").warning("could not read the scripts a restart killed: \(error)")
      return
    }
    for owner in owners {
      var text = "script \(owner.script) was killed by a server restart"
      if !owner.live.isEmpty {
        let ids = owner.live.map(\.rawValue).joined(separator: ", ")
        text += "; the machine processes it left running (\(ids)) get killed about a minute after the restart, or when their machine reconnects if it is away then"
      }
      await notify(space, SessionID(rawValue: owner.session), script: owner.script, text)
    }
  }

  func start(_ source: String, session: SessionID, lifetime: Duration, tools: ToolExecutor) -> ScriptExecution {
    @Dependency(\.uuid) var uuid
    let id = String(uuid().uuidString.lowercased().prefix(8))
    let execution = ScriptExecution(
      id: id,
      session: session,
      source: source,
      lifetime: lifetime,
      secrets: ScriptSecrets(stores: secrets, space: space, session: session),
      tools: tools,
      machines: machines,
    )
    running.withLock { $0[id] = execution }
    launch.yield(execution)
    return execution
  }

  func execution(_ id: String, of session: SessionID) -> ScriptExecution? {
    running.withLock { $0[id] }.flatMap { $0.session == session ? $0 : nil }
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
    let execution = scripts.start(arguments.source, session: session, lifetime: .seconds(lifetime), tools: self)
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
    guard let execution = scripts?.execution(arguments.id, of: session) else {
      throw ToolProblem("stop_script: you have no running script \(arguments.id)")
    }
    let output = switch await execution.stop() {
    case let .killed(stop): "script \(execution.id) was killed: \(stop.killReason)"
    case .released, .failed: "script \(execution.id) stopped"
    }
    return .script(.init(output: output))
  }
}

public struct ScriptIdentityUnavailable: Error, Sendable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}
