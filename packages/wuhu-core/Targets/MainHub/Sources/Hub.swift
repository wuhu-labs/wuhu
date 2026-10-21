import struct Credentials.SpaceSecretStores
import Fetch
import Synchronization
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.CapabilityError
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
  nonisolated let sessionAccess: SessionAccess
  nonisolated public let space: Space
  nonisolated let secrets: SpaceSecretStores?
  nonisolated public let machines: MachineSeam?
  nonisolated let resolveModelExecutor: (@Sendable (_ provider: String, _ model: String, _ effort: String?) async throws -> SessionExecutor)?
  nonisolated let resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)?
  nonisolated let prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)?

  public init(
    space: Space,
    sessionAccess: SessionAccess = .init(),
    secrets: SpaceSecretStores? = nil,
    machines: MachineSeam? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    resolveModelGroup: (@Sendable (String, String?) async throws -> SessionExecutor)? = nil,
    prepareModelRoute: (@Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute?)? = nil,
  ) {
    self.sessionAccess = sessionAccess
    self.space = space
    self.secrets = secrets
    self.machines = machines
    self.resolveModelExecutor = resolveModelExecutor
    self.resolveModelGroup = resolveModelGroup
    self.prepareModelRoute = prepareModelRoute
  }

  nonisolated var store: SessionStore { space.sessions }

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
}
