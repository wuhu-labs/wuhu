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
import Fetch
import struct InferenceKit.CapabilityError
import struct InferenceKit.ProviderCatalog
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import SessionDomain
import SpaceClient
import struct SpaceContract.ToolError
import SpaceCore
import SpaceTools
import struct WuhuAI.ToolCall

public struct ToolExecutor: Sendable {
  let owner: any Main
  let main: MainConnection
  let credential: @Sendable (SessionID) async throws -> String
  let credentials: CredentialResolver
  let completionCatalog: (@Sendable () async throws -> ProviderCatalog)?
  let scripts: Scripts?

  /// `credential` is the token main issued the session; every call the worker
  /// makes to main's API carries it.
  public init(
    owner: any Main,
    main: MainConnection,
    credential: @escaping @Sendable (SessionID) async throws -> String,
    credentials: CredentialResolver = .unavailable,
    completionCatalog: (@Sendable () async throws -> ProviderCatalog)? = nil,
    scripts: Scripts? = nil,
  ) {
    self.owner = owner
    self.main = main
    self.credential = credential
    self.credentials = credentials
    self.completionCatalog = completionCatalog
    self.scripts = scripts
  }

  /// Main's API as `session`.
  func client(_ session: SessionID) async throws -> SpaceClient {
    let token = try await credential(session)
    let main = main
    return SpaceClient(space: "http://main", fetch: FetchClient { request in
      var request = request
      request.headers[.authorization] = "Bearer " + token
      return try await main.fetch(request)
    })
  }

  public func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolOutcome {
    guard let tool = RosterTool(rawValue: call.name) else {
      return ToolOutcome(payload: .failure(.init(message: "unknown tool: \(call.name)")))
    }
    let (call, touched) = await resolvingMachine(session, tool, call)
    let payload = try await result(session, tool, call, state: state)
    if case .failure = payload { return ToolOutcome(payload: payload) }
    return ToolOutcome(payload: payload, context: await deliverContext(session, touching: touched, state: state))
  }

  private func result(_ session: SessionID, _ tool: RosterTool, _ call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload {
    do {
      switch tool {
      case .runScript: return try await runScript(session, decoded(RunScriptArguments.self, call))
      case .cancel: return try await cancel(session, decoded(CancelArguments.self, call), call: call, state: state)
      case .generateImage: return try await generateImage(session, ToolCallID(call.id), decoded(GenerateImageArguments.self, call))
      case .grep: return try await grep(session, decoded(GrepArguments.self, call))
      case .find: return try await find(session, decoded(FindArguments.self, call))
      case .query: return try await query(session, decoded(QueryArguments.self, call))
      default: return try await owner.execute(session: session, call: call, state: state)
      }
    } catch let error as CapabilityError { return .failure(.init(message: error.description)) }
    catch let error as OperationError { return .failure(.init(message: error.message.isEmpty ? error.code.rawValue : error.message, code: error.code.rawValue)) }
    catch let error as ToolProblem { return .failure(.init(message: error.message, code: error.code)) }
    catch let error as ToolRunError { return .failure(.init(message: renderedFailure(error), code: error.payload.object?["code"]?.stringValue)) }
    catch let error as SpaceError { return .failure(.init(message: renderedFailure(Wire.failure(error)))) }
    catch let error as SpaceClient.ToolFailure { return .failure(.init(message: rendered(error.error), code: error.error.code.rawValue)) }
    catch let error as SpaceClient.TransportFailure { return .failure(.init(message: error.message, code: error.code)) }
    catch let error as MainUnavailable { return .failure(.init(message: error.description)) }
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

// Main's refusal as the model reads it, the same line `renderedFailure` makes
// of a tool run that failed in process.
private func rendered(_ error: ToolError) -> String {
  var text = "\(error.code.rawValue): \(error.message)"
  if let hint = error.hint { text += " (\(hint))" }
  if let token = error.token { text += " [current token: \(token)]" }
  return text
}
