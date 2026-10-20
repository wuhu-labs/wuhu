import struct Credentials.CredentialResolver
import struct InferenceKit.ProviderCatalog
import protocol MainHub.Main
import enum MainHub.RevocationPolicy
import struct MainHub.ScriptHandlerInvocation
import struct MainHub.ScriptHandlerResult
import protocol MainHub.Worker
import struct MainHub.WorkerActivity
import enum MainHub.WorkerInput
import SessionTools
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import struct WuhuAI.ToolCall

public struct SessionExecution: Worker {
  private let registry: SessionRegistry
  private let liveness = LivenessTracker()
  private let scripts: Scripts
  private let execJobs: ExecJobs
  private let tools: ToolExecutor
  private let scope = TaskScope()

  public init(
    main: any Main,
    connection: MainConnection,
    credential: @escaping @Sendable (SessionID) async throws -> String,
    credentials: CredentialResolver = .unavailable,
    completionCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
    execJobs: ExecJobs = ExecJobs(),
    loopConfig: @Sendable (ToolExecutor) -> LoopConfig,
  ) async {
    let scripts = Scripts(owner: main)
    let tools = ToolExecutor(
      owner: main, main: connection, credential: credential, credentials: credentials, completionCatalog: completionCatalog, scripts: scripts, execJobs: execJobs,
    )
    self.execJobs = execJobs
    self.scripts = scripts
    self.tools = tools
    var config = loopConfig(tools)
    let runningWork = config.runningWork
    config.runningWork = { session in scripts.running(of: session) + (try await runningWork(session)) }
    registry = SessionRegistry(main: main, loopConfig: config, liveness: liveness)
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
      await registry.archived(session)
    }
  }

  public func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    try await registry.revoke(session, policy: policy)
  }

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
    return try await scripts.runHandler(
      id: invocation.id, path: invocation.path, session: invocation.session,
      rows: rows, fireTime: fireTime, stateJSON: invocation.stateJSON, tools: tools,
    )
  }

  public func activity() async -> WorkerActivity { scripts.activity }

  public func drain() async {
    _ = try? scope.run("worker-scripts") { await scripts.run() }
    await withTaskCancellationHandler {
      await liveness.drain()
    } onCancel: {
      scope.cancel()
    }
    await scope.close()
  }

  public func shutdown() async {
    await registry.stop()
    await execJobs.close()
    await scope.close()
  }
}
