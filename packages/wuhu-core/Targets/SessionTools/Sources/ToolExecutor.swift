import struct Credentials.CredentialResolver
import struct MainHub.CancelArguments
import protocol MainHub.Main
import func MainHub.renderedFailure
import enum MainHub.RosterTool
import struct MainHub.ToolProblem
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.CapabilityError
import struct InferenceKit.ProviderCatalog
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import SessionDomain
import SpaceCore
import SpaceTools
import struct WuhuAI.ToolCall

public struct ToolExecutor: Sendable {
  let owner: any Main
  let credentials: CredentialResolver
  let completionCatalog: (@Sendable () async throws -> ProviderCatalog)?
  let scripts: Scripts?

  public init(
    owner: any Main,
    credentials: CredentialResolver = .unavailable,
    completionCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
    scripts: Scripts? = nil,
  ) {
    self.owner = owner
    self.credentials = credentials
    self.completionCatalog = completionCatalog
    self.scripts = scripts
  }

  public func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload {
    guard let tool = RosterTool(rawValue: call.name) else {
      return .failure(.init(message: "unknown tool: \(call.name)"))
    }
    do {
      switch tool {
      case .runScript: return try await runScript(session, decoded(RunScriptArguments.self, call))
      case .cancel: return try await cancel(session, decoded(CancelArguments.self, call), call: call, state: state)
      case .generateImage: return try await generateImage(session, ToolCallID(call.id), decoded(GenerateImageArguments.self, call), state: state)
      default: return try await owner.execute(session: session, call: call, state: state)
      }
    } catch let error as CapabilityError { return .failure(.init(message: error.description)) }
    catch let error as OperationError { return .failure(.init(message: error.message.isEmpty ? error.code.rawValue : error.message, code: error.code.rawValue)) }
    catch let error as ToolProblem { return .failure(.init(message: error.message, code: error.code)) }
    catch let error as ToolRunError { return .failure(.init(message: renderedFailure(error), code: error.payload.object?["code"]?.stringValue)) }
    catch let error as SpaceError { return .failure(.init(message: renderedFailure(Wire.failure(error)))) }
    catch is CancellationError { throw CancellationError() }
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
