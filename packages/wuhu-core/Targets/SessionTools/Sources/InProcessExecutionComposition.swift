import Credentials
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceTools

public extension ToolExecutor {
  init(
    space: Space,
    machines: MachineSeam? = nil,
    exec: ExecBackend? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
    prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
    credentials: CredentialResolver = .unavailable,
    completionCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
    completionMetrics: InferenceMetricsSink? = nil,
    scripts: Scripts? = nil,
    control: SessionControl? = nil,
  ) {
    self.init(
      owner: InProcessToolOwnerClient(
        space: space,
        machines: machines,
        exec: exec,
        resolveModelExecutor: resolveModelExecutor,
        resolveModelGroup: resolveModelGroup,
        prepareModelRoute: prepareModelRoute,
        credentials: credentials,
        completionMetrics: completionMetrics,
        control: control,
      ),
      credentials: credentials,
      completionCatalog: completionCatalog,
      scripts: scripts,
    )
  }
}

public extension Scripts {
  convenience init(
    space: Space,
    secrets: SpaceSecretStores? = nil,
    machines: ScriptMachineAccess? = nil,
    machinesV2: ScriptMachineV2Access? = nil,
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
  ) {
    self.init(
      owner: InProcessToolOwnerClient(space: space, secrets: secrets, identityFetch: identityFetch, scriptMachines: machines, scriptMachinesV2: machinesV2),
    )
  }
}

public extension SubscriptionFiring {
  init(space: Space, scripts: Scripts? = nil, tools: ToolExecutor? = nil) {
    let handler: (any HandlerExecutionClient)?
    if let scripts, let tools { handler = ScriptHandlerExecutor(scripts: scripts, tools: tools) }
    else { handler = nil }
    self.init(space: space, handler: handler)
  }
}

extension Scripts {
  public func configureDiscovery(contentHost: String? = nil, toolRosters: ToolRostersOutput? = nil, identity: (@Sendable () async throws -> JSONValue)? = nil) {
    if let identity {
      guard let adapter = owner as? InProcessToolOwnerClient else {
        preconditionFailure("identity configuration is parent in-process composition")
      }
      adapter.identityConfigurationProvider.value.withLock { $0 = identity }
    }
    discovery.withLock {
      if let contentHost { $0.contentHost = contentHost }
      if let toolRosters { $0.toolRosters = toolRosters }
    }
  }
}

public extension InProcessToolOwnerClient {
  init(
    space: Space,
    secrets: SpaceSecretStores? = nil,
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
    machines: MachineSeam? = nil,
    exec: ExecBackend? = nil,
    scriptMachines: ScriptMachineAccess? = nil,
    scriptMachinesV2: ScriptMachineV2Access? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
    prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
    credentials: CredentialResolver = .unavailable,
    completionMetrics: InferenceMetricsSink? = nil,
    control: SessionControl? = nil,
  ) {
    self.init(
      space: space,
      executionOwner: InProcessExecutionOwnerClient(space: space, metrics: completionMetrics ?? .noop, credentials: credentials),
      secrets: secrets,
      identityFetch: identityFetch,
      machines: machines,
      exec: exec,
      scriptMachines: scriptMachines,
      scriptMachinesV2: scriptMachinesV2,
      resolveModelExecutor: resolveModelExecutor,
      resolveModelGroup: resolveModelGroup,
      prepareModelRoute: prepareModelRoute,
      completionMetrics: completionMetrics,
      control: control,
    )
  }
}
