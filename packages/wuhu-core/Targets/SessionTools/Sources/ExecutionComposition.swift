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
      owner: Hub(
        space: space,
        credentials: credentials,
        machines: machines,
        exec: exec,
        resolveModelExecutor: resolveModelExecutor,
        resolveModelGroup: resolveModelGroup,
        prepareModelRoute: prepareModelRoute,
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
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
  ) {
    self.init(
      owner: Hub(space: space, secrets: secrets, identityFetch: identityFetch, scriptMachines: machines),
    )
  }
}

public extension SubscriptionFiring {
  init(space: Space, scripts: Scripts? = nil, tools: ToolExecutor? = nil) {
    let handler: (any HandlerExecutionClient)?
    if let scripts, let tools { handler = ScriptHandlerExecutor(scripts: scripts, tools: tools) }
    else { handler = nil }
    self.init(space: space, handler: handler, scripts: scripts)
  }
}

extension Scripts {
  public func configureDiscovery(contentHost: String? = nil, toolRosters: ToolRostersOutput? = nil) {
    discovery.withLock {
      if let contentHost { $0.contentHost = contentHost }
      if let toolRosters { $0.toolRosters = toolRosters }
    }
  }
}
