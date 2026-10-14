import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import protocol ExecutionOwner.ExecutionOwnerClient
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

public struct InProcessToolOwnerClient: WorkerOwnerClient {
  let identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)?
  let identityConfigurationProvider = InProcessIdentityConfiguration()
  let executionOwner: any ExecutionOwnerClient
  public let scriptMachines: ScriptMachineAccess?
  public let scriptMachinesV2: ScriptMachineV2Access?
  let space: Space
  let secrets: SpaceSecretStores?
  let machines: MachineSeam?
  let execBackend: ExecBackend?
  let resolveModelExecutor: (@Sendable (_ provider: String, _ model: String, _ effort: String?) async throws -> SessionExecutor)?
  let resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)?
  let prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)?
  let completionMetrics: InferenceMetricsSink?
  let control: SessionControl?

  public init(
    space: Space,
    executionOwner: any ExecutionOwnerClient,
    secrets: SpaceSecretStores? = nil,
    identityFetch: (@Sendable (Request, SessionID, @Sendable (String) -> Void) async throws -> Response)? = nil,
    machines: MachineSeam? = nil,
    exec: ExecBackend? = nil,
    scriptMachines: ScriptMachineAccess? = nil,
    scriptMachinesV2: ScriptMachineV2Access? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
    prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
    completionMetrics: InferenceMetricsSink? = nil,
    control: SessionControl? = nil,
  ) {
    self.identityFetch = identityFetch
    self.executionOwner = executionOwner
    self.scriptMachines = scriptMachines
    self.scriptMachinesV2 = scriptMachinesV2
    self.space = space
    self.secrets = secrets
    self.machines = machines
    execBackend = exec
    self.resolveModelExecutor = resolveModelExecutor
    self.resolveModelGroup = resolveModelGroup
    self.prepareModelRoute = prepareModelRoute
    self.completionMetrics = completionMetrics
    self.control = control
  }

  var store: SessionStore { space.sessions }

  public func execute(
    session: SessionID,
    call: ToolCall,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    guard let tool = RosterTool(rawValue: call.name) else {
      return .failure(.init(message: "unknown tool: \(call.name)"))
    }
    do {
      return try await run(tool, session: session, call: call, state: state)
    } catch let error as ExecutorUnavailableError {
      return .failure(.init(message: error.description, code: "executorNoLongerSupported"))
    } catch let error as CapabilityError {
      return .failure(.init(message: error.description))
    } catch let problem as ToolProblem {
      return .failure(.init(message: problem.message, code: problem.code))
    } catch let error as ToolRunError {
      return .failure(.init(message: renderedFailure(error)))
    } catch let error as SpaceError {
      return .failure(.init(message: renderedFailure(Wire.failure(error))))
    } catch is CancellationError {
      throw CancellationError()
    }
  }

  private func run(
    _ tool: RosterTool,
    session: SessionID,
    call: ToolCall,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let callID = ToolCallID(call.id)
    switch tool {
    case .read:
      return try await read(session, callID, decoded(ReadArguments.self, call), state: state)
    case .write:
      return try await write(session, callID, decoded(WriteArguments.self, call), state: state)
    case .edit:
      return try await edit(session, callID, decoded(EditArguments.self, call), state: state)
    case .grep:
      return try await grep(session, callID, decoded(GrepArguments.self, call), state: state)
    case .find:
      return try await find(session, callID, decoded(FindArguments.self, call), state: state)
    case .exec:
      return try await exec(session, callID, decoded(ExecArguments.self, call), state: state)
    case .machines:
      return try await machineRoster(session)
    case .templates:
      return try await templateRoster(session)
    case .observe:
      return try await observe(session, callID, decoded(ObserveArguments.self, call))
    case .timer:
      return try await timer(session, callID, decoded(TimerArguments.self, call))
    case .cancelObservation:
      return try await cancel(.observation, session, decoded(CancelArguments.self, call), state: state)
    case .cancelTimer:
      return try await cancel(.timer, session, decoded(CancelArguments.self, call), state: state)
    case .query:
      return try await query(session, decoded(QueryArguments.self, call))
    case .sendMessage:
      if case let .object(fields) = call.arguments.json, fields["user"] != nil {
        throw problem(.humanAgentDirectMessage)
      }
      return try await sendMessage(session, callID, decoded(SendMessageArguments.self, call))
    case .request:
      return try await request(session, callID, decoded(RequestArguments.self, call))
    case .report:
      return try await report(session, callID, decoded(ReportArguments.self, call))
    case .createSession:
      return try await createSession(session, callID, decoded(CreateSessionArguments.self, call))
    case .setTitle:
      return try await setTitle(session, decoded(SetTitleArguments.self, call))
    case .manipulateUI:
      return try await manipulateUI(session, decoded(ManipulateUIArguments.self, call))
    case .generateImage, .runScript, .stopScript:
      preconditionFailure("worker execution must not enter the persistent dispatcher")
    }
  }

  private func decoded<Arguments: Decodable>(
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
