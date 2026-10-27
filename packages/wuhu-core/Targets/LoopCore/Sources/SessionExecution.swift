import protocol MainHub.Main
import enum MainHub.RevocationPolicy
import struct MainHub.ScriptHandlerInvocation
import struct MainHub.ScriptHandlerResult
import struct MainHub.ScriptRun
import func MainHub.withCallback
import protocol MainHub.Worker
import struct MainHub.WorkerActivity
import enum MainHub.WorkerInput
import SessionTools
import enum SpaceContract.ScriptOutput
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import struct WuhuAI.ToolCall

/// A worker: the loops, the tools and the scripts of the sessions main
/// assigns to it. It runs from when it is made until `shutdown`.
public struct SessionExecution: Worker {
  private let registry: SessionRegistry
  private let scripts: Scripts
  private let execJobs: ExecJobs
  private let tools: ToolExecutor
  private let running: @Sendable (SessionID) async throws -> [String]

  public init(
    main: any Main,
    connection: MainConnection,
    credential: @escaping @Sendable (SessionID) async throws -> String,
    access: InferenceAccess = InferenceAccess(),
    execJobs: ExecJobs = ExecJobs(),
    loopConfig: @Sendable (ToolExecutor) -> LoopConfig,
  ) async {
    let scripts = Scripts(owner: main)
    let tools = ToolExecutor(
      owner: main, main: connection, credential: credential, access: access, scripts: scripts, execJobs: execJobs,
    )
    self.execJobs = execJobs
    self.scripts = scripts
    self.tools = tools
    var config = loopConfig(tools)
    let runningWork = config.runningWork
    config.runningWork = { session in
      scripts.running(of: session) + tools.runningExecJobs(of: session) + (try await runningWork(session))
    }
    running = config.runningWork
    let mounted = config.mounted
    config.mounted = { session, transcript in
      await tools.adoptExecJobs(of: session, pending: Set(transcript.pendingToolCallIDs))
      await mounted(session, transcript)
    }
    registry = SessionRegistry(main: main, loopConfig: config)
    await registry.activate()
  }

  public func deliver(_ session: SessionID, _ input: WorkerInput) async throws {
    switch input {
    case .wake:
      try await withCallback(of: Void.self) { registry.send(.wake($0), to: session) }
    case .interrupt:
      try await withCallback(of: Void.self) { registry.send(.interrupt($0), to: session) }
    case .resume:
      try await withCallback(of: Void.self) { registry.send(.resume($0), to: session) }
    case .reload: try await registry.reload(session)
    case .archived:
      scripts.stopScripts(of: session)
      await tools.cancelExecJobs(of: session)
      await registry.archived(session)
    }
  }

  public func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    let settled = try await registry.revoke(session, policy: policy)
    // What the session left running outside its loop goes with it: the next
    // worker adopts it when it mounts the session.
    if settled, case .handOff = policy { await tools.releaseExecJobs(of: session) }
    return settled
  }

  /// A tool call run here as the loop runs it: what tests of the tools take.
  public func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolOutcome {
    try await tools.execute(session: session, call: call, state: state)
  }

  public func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    let rows: Rows?
    let fireTime: Date?
    switch invocation.input {
    case let .rows(value): rows = value; fireTime = nil
    case let .timer(value): rows = nil; fireTime = value
    }
    let actor: ScriptActor
    switch invocation.runner {
    case let .session(session): actor = .session(session)
    case let .observer(observer):
      guard let token = invocation.token else { preconditionFailure("an observer's firing reached the worker without its token") }
      actor = .observer(observer, token: token)
    }
    return try await scripts.runHandler(
      id: invocation.id, path: invocation.path, actor: actor,
      rows: rows, fireTime: fireTime, stateJSON: invocation.stateJSON, tools: tools,
    )
  }

  public func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    try await scripts.run(script, tools: tools, output: output)
  }

  public func activity() async -> WorkerActivity { scripts.activity }

  /// The sessions this worker holds: what it announces again when it opens
  /// a new line to main.
  public func holding() async -> [SessionID] { await registry.mounted() }

  public func runningWork(_ session: SessionID) async throws -> [String] { try await running(session) }

  public func shutdown() async {
    await registry.stop()
    await scripts.close()
    await execJobs.close()
  }
}
