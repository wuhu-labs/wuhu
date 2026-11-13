import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import ExecutionOwner
import struct FileSearch.SearchError
import struct MainHub.EventSources
import class MainHub.Hub
import struct MainHub.SessionEffects
import TaskLifetime
import enum Wuwei.Storage
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import InferenceKit
import JSONValue
import Logging
import LoopCore
import struct MachineContract.ExecID
import ModelProviders
import enum ModelProviders.ModelPlacementReason
import struct OperationProtocol.OperationError
import Serve
import SessionDomain
import SessionTools
import enum SpaceContract.ErrorCode
import enum SpaceContract.SessionToolExecutor
import SpaceCore
import SpaceTools
import Synchronization
import SystemFiles
import WuhuAI

public struct SessionRuntime: Sendable {
  let streamScope = TaskScope()
  /// The sessions' loops, tools and scripts, and the verbs the routes take for a session.
  public let execution: SessionExecution
  /// What a session's tools present to main's API, and the line they present it over.
  let tokens: ExecTokens
  let connection: MainConnection
  let store: SessionStore
  let sockets: ResponsesSocketRegistry?
  let owner: Hub
  /// Where an inference a session reports lands: `POST /v1/inferences`.
  let metrics: InferenceMetricsSink
  private let startup: (@Sendable () async -> Void)?
  let usage: UsageBoard
  let refresher: UsageRefresher?
  let resolveModelExecutor: @Sendable (String, String, String?) async throws -> SessionExecutor
  let resolveModelGroup: @Sendable (String, String?) async throws -> SessionExecutor
  let prepareModelRoute: @Sendable (SessionExecutor, ModelPlacementReason, SessionModelRoute?) async throws -> SessionModelRoute?
  let budget: @Sendable (SessionID) async -> ContextBudget

  init(
    execution: SessionExecution, owner: Hub, access: InferenceAccess = InferenceAccess(), metrics: InferenceMetricsSink = .noop,
    tokens: ExecTokens, connection: MainConnection,
  ) {
    let usage = UsageBoard()
    self.init(
      execution: execution, usage: usage, sockets: ResponsesSocketRegistry(), refresher: nil, owner: owner, metrics: metrics,
      catalog: groupCatalog(space: owner.space, access: access), tokens: tokens, connection: connection,
    )
  }

  init(
    execution: SessionExecution,
    usage: UsageBoard,
    sockets: ResponsesSocketRegistry?,
    refresher: UsageRefresher?,
    startup: (@Sendable () async -> Void)? = nil,
    owner: Hub,
    metrics: InferenceMetricsSink,
    catalog: @escaping @Sendable () async throws -> ProviderCatalog,
    tokens: ExecTokens,
    connection: MainConnection,
  ) {
    let space = owner.space
    self.startup = startup
    self.execution = execution
    self.metrics = metrics
    self.tokens = tokens
    self.connection = connection
    store = space.sessions
    self.usage = usage
    self.sockets = sockets
    self.refresher = refresher
    self.owner = owner
    resolveModelExecutor = modelExecutorResolver(space: space)
    resolveModelGroup = modelGroupExecutorResolver(catalog: catalog)
    prepareModelRoute = modelRoutePlacer(catalog: catalog, usage: usage)
    budget = budgetResolver(space: space)
  }

  /// Starts the sessions, once main's API is bound to their tools, and runs until cancelled.
  public func run() async {
    await startup?()
    execution.start()
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        let (parking, continuation) = AsyncStream<Void>.makeStream()
        for await _ in parking {}
        continuation.finish()
        await execution.quiesce()
      }
      if let sockets { group.addTask { await sockets.run() } }
      if let refresher {
        group.addTask { await refresher.run() }
      }
      await group.waitForAll()
    }
    await streamScope.close()
  }
}

extension SessionRuntime {
  static func assemble(
    space: Space,
    hub: MachineHub,
    attemptLog: AttemptLogConfig? = nil,
    metrics: InferenceMetricsSink = .noop,
    credentials: CredentialResolver = .environmentOnly,
    secrets: SpaceSecretStores? = nil,
    tokens: ExecTokens,
  ) async -> SessionRuntime {
    await assemble(
      space: space, hub: hub, attemptLog: attemptLog, metrics: metrics, credentials: credentials,
      secrets: secrets, usage: UsageBoard(), tokens: tokens,
    )
  }

  static func assemble(
    space: Space,
    hub: MachineHub,
    attemptLog: AttemptLogConfig?,
    metrics: InferenceMetricsSink,
    credentials: CredentialResolver,
    secrets: SpaceSecretStores?,
    usage: UsageBoard,
    tokens: ExecTokens,
    oidcToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    oidcReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    eventSources: EventSources? = nil,
  ) async -> SessionRuntime {
    let connection = MainConnection()
    // What this process brings to the inferences it runs; the catalog is data
    // in the space (`wuhu models update`), re-read per use, never cached at boot.
    let access = InferenceAccess(
      credentials: credentials, oidcToken: oidcToken, oidcReadiness: oidcReadiness, oidcBindingIdentity: oidcBindingIdentity,
      trace: attemptLog?.traceClient,
    )
    let catalog = groupCatalog(space: space, access: access)
    let worker = KernelWorker(
      connection: connection, tokens: tokens, machines: hub, access: access, usage: usage,
      sources: eventSources ?? .unavailable, space: space,
    )
    let toolOwner = withDependencies {
      $0[SessionEffects.self] = worker.execution.sessionEffects
    } operation: {
      Hub(
        space: space,
        secrets: secrets,
        machines: machineSeam(hub: hub),
        resolveModelExecutor: modelExecutorResolver(space: space),
        resolveModelGroup: modelGroupExecutorResolver(catalog: catalog),
        prepareModelRoute: modelRoutePreparer(catalog: catalog, usage: usage),
      )
    }
    return SessionRuntime(
      execution: worker.execution,
      usage: usage,
      sockets: worker.sockets,
      refresher: UsageRefresher(board: usage, space: space, credentials: credentials),
      owner: toolOwner, metrics: metrics, catalog: catalog,
      tokens: tokens, connection: connection,
    )
  }
}

// MARK: - In-process tools

extension SessionRuntime {
  @discardableResult
  static func bindMain(
    owner: Hub, execution: SessionExecution, tokens: ExecTokens, connection: MainConnection, hub: MachineHub? = nil,
    origin: String? = nil, contentHostPattern: String? = nil, credentials: CredentialResolver = .unavailable, secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> UpgradingHandler {
    let runtime = SessionRuntime(
      execution: execution, owner: owner, metrics: .recording(in: owner.space), tokens: tokens, connection: connection,
    )
    return SpaceServer.configuredHandler(
      space: owner.space, hub: hub ?? MachineHub(space: owner.space), sessions: runtime, origin: origin, contentHostPattern: contentHostPattern,
      devPerson: nil, credentials: credentials, secrets: secrets, identityController: identity, machines: owner.machines,
    )
  }

  static func toolExecutor(
    owner: Hub,
    execution: SessionExecution,
    tokens: ExecTokens,
    hub: MachineHub? = nil,
    access: InferenceAccess = InferenceAccess(),
    origin: String? = nil,
    contentHostPattern: String? = nil,
    secrets: SpaceSecretStores? = nil,
    identity: IdentityController? = nil,
  ) -> ToolExecutor {
    let connection = MainConnection()
    bindMain(
      owner: owner, execution: execution, tokens: tokens, connection: connection, hub: hub,
      origin: origin, contentHostPattern: contentHostPattern, credentials: access.credentials, secrets: secrets, identity: identity,
    )
    return ToolExecutor(main: connection, credential: { try await tokens.sessionToken($0) }, access: access)
  }
}

func modelExecutorResolver(space: Space) -> @Sendable (String, String, String?) async throws -> SessionExecutor {
  { provider, model, effort in
    let data = try await space.fs(.settings).read(ModelsDocument.spacePath).1
    let catalog = ProviderCatalog(document: try ModelsDocument(json: data), credentials: .unavailable)
    if let effort {
      let specifier = ModelSpecifier(provider: provider, model: model, effort: effort)
      try catalog.validate(specifier)
      return .kernel(specifier)
    }
    return try .kernel(catalog.defaultSpecifier(provider: provider, model: model))
  }
}

func machineSeam(hub: MachineHub) -> MachineSeam {
  MachineSeam(
    vfs: { machine, op in
      do { return try await hub.vfs(machine: machine, op: op, caller: MachineSeam.caller) }
      catch let error as MachineHubError { throw toolFailure(error, machine: machine) }
      catch let error as OperationError { throw Wire.failure(MachineFileFailure.operation(error)) }
      catch let error as MachineFileFailure { throw Wire.failure(error) }
    },
    search: { machine, query in
      do { return try await hub.search(machine: machine, query: query, caller: MachineSeam.caller) }
      catch let error as MachineHubError { throw toolFailure(error, machine: machine) }
      catch let error as OperationError { throw Wire.failure(MachineFileFailure.operation(error)) }
      catch let error as MachineFileFailure { throw Wire.failure(error) }
      catch let error as SearchError { throw searchFailure(error) }
    },
    copy: { source, target in
      do { return try await hub.copy(from: source, to: target, caller: MachineSeam.caller) }
      catch let error as MachineHubError {
        guard case let .machineUnattached(machine) = error else { throw error }
        throw toolFailure(error, machine: machine)
      } catch let error as OperationError { throw Wire.failure(MachineFileFailure.operation(error)) }
    },
    attached: { await hub.attachedMachines() },
  )
}
