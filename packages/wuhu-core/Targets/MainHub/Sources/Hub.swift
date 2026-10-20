import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import struct ExecutionOwner.AttemptLogConfig
import Fetch
import Synchronization
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.CapabilityError
import struct InferenceKit.InferenceMetricsSink
import struct InferenceKit.ProviderCatalog
import JSONValue
import protocol MachineChannel.FrameTransport
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import SessionDomain
import SpaceCore
import SpaceTools
import struct WuhuAI.ToolCall

public actor Hub: Main {
  nonisolated let identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)?
  nonisolated let scriptDiscovery = ScriptDiscoveryConfiguration()
  nonisolated let sessionAccess: SessionAccess
  nonisolated let attemptLog: AttemptLogConfig?
  nonisolated let metrics: InferenceMetricsSink
  nonisolated let credentials: CredentialResolver
  nonisolated let readiness: (@Sendable (URL) async throws -> Void)?
  nonisolated let bindingIdentity: (@Sendable (URL, SessionID) async throws -> String)?
  nonisolated let token: (@Sendable (URL, SessionID) async throws -> String)?
  nonisolated let scriptExecConnections = ScriptExecConnections()

  nonisolated let scriptMachines: ScriptMachineAccess?
  nonisolated public let space: Space
  nonisolated let secrets: SpaceSecretStores?
  nonisolated public let machines: MachineSeam?
  nonisolated let execBackend: ExecBackend?
  nonisolated let execJobs: ExecJobs
  nonisolated let resolveModelExecutor: (@Sendable (_ provider: String, _ model: String, _ effort: String?) async throws -> SessionExecutor)?
  nonisolated let resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)?
  nonisolated let prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)?
  nonisolated let completionMetrics: InferenceMetricsSink?
  nonisolated let control: SessionControl?

  public init(
    space: Space,
    sessionAccess: SessionAccess = .init(),
    identityConfiguration: (@Sendable () async throws -> JSONValue)? = nil,
    metrics: InferenceMetricsSink = .noop,
    credentials: CredentialResolver = .unavailable,
    inferenceToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    inferenceReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    inferenceBindingIdentity: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    attemptLog: AttemptLogConfig? = nil,
    secrets: SpaceSecretStores? = nil,
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
    machines: MachineSeam? = nil,
    exec: ExecBackend? = nil,
    scriptMachines: ScriptMachineAccess? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
    prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
    completionMetrics: InferenceMetricsSink? = nil,
    control: SessionControl? = nil,
    execJobs: ExecJobs = ExecJobs(),
  ) {
    self.identityFetch = identityFetch
    scriptDiscovery.value.withLock { $0 = identityConfiguration }
    self.sessionAccess = sessionAccess
    self.metrics = metrics
    self.credentials = credentials
    self.attemptLog = attemptLog
    token = inferenceToken
    readiness = inferenceReadiness
    bindingIdentity = inferenceBindingIdentity
    self.scriptMachines = scriptMachines
    self.space = space
    self.secrets = secrets
    self.machines = machines
    execBackend = exec
    self.execJobs = execJobs
    self.resolveModelExecutor = resolveModelExecutor
    self.resolveModelGroup = resolveModelGroup
    self.prepareModelRoute = prepareModelRoute
    self.completionMetrics = completionMetrics
    self.control = control
  }

  nonisolated var store: SessionStore { space.sessions }

  // The tools main still runs for the worker: exec, and the exec half of
  // cancel. Every other tool is the worker's, over main's API.
  nonisolated public func execute(
    session: SessionID,
    call: ToolCall,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    try await answering(as: session) {
      let callID = ToolCallID(call.id)
      switch RosterTool(rawValue: call.name) {
      case .exec:
        return try await exec(session, callID, decoded(ExecArguments.self, call), state: state)
      case .cancel:
        guard case let .exec(id) = try CancelTarget(decoded(CancelArguments.self, call).id) else {
          preconditionFailure("the worker cancels its own subscriptions and scripts")
        }
        return try await cancelExec(session, id)
      case nil:
        return .failure(.init(message: "unknown tool: \(call.name)"))
      default:
        preconditionFailure("worker-owned tools must not enter the persistent dispatcher")
      }
    }
  }

  /// A session verb's answer as the model reads it: `body` runs as `session`
  /// (a machine it reaches sees the session as its caller) and whatever it
  /// throws of the typed kinds becomes a tool failure.
  nonisolated public func answering(as session: SessionID, _ body: @Sendable () async throws -> ToolResultPayload) async throws -> ToolResultPayload {
    do {
      return try await MachineSeam.$caller.withValue(session, operation: body)
    } catch let error as ExecutorUnavailableError {
      return .failure(.init(message: error.description, code: "executorNoLongerSupported"))
    } catch let error as CapabilityError {
      return .failure(.init(message: error.description))
    } catch let problem as ToolProblem {
      return .failure(.init(message: problem.message, code: problem.code))
    } catch let error as ToolRunError {
      return .failure(.init(message: renderedFailure(error), code: error.payload.object?["code"]?.stringValue))
    } catch let error as SpaceError {
      return .failure(.init(message: renderedFailure(Wire.failure(error))))
    } catch is CancellationError {
      throw CancellationError()
    }
  }

  nonisolated private func decoded<Arguments: Decodable>(
    _ type: Arguments.Type,
    _ call: ToolCall,
  ) throws(ToolProblem) -> Arguments {
    do {
      return try JSONValueDecoder().decode(type, from: call.arguments.json)
    } catch {
      throw ToolProblem("\(call.name): arguments do not match the tool schema: \(error)")
    }
  }
}
