import struct Credentials.CredentialResolver
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
import struct OperationProtocol.OperationError
import SessionDomain
import SpaceCore
import SpaceTools
import struct WuhuAI.ToolCall

// A model-facing failure: rendered into the transcript as a typed tool
// failure, never thrown past the executor.
struct ToolProblem: Error {
  var message: String
  var code: String?

  init(_ message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }
}

public struct ExecBackend: Sendable {
  public var claim: @Sendable (MachineID, SessionID, ToolCallID) async throws -> ExecClaim
  public var connect: @Sendable (ExecID) async throws -> any FrameTransport
  public var status: @Sendable (ExecID) async throws -> ExecRecord?
  // Mints an exec owned by a run_script execution: (machine, session, script id).
  public var mintScript: @Sendable (MachineID, SessionID, String) async throws -> ExecRecord
  public var kill: @Sendable (ExecID) async throws -> Void

  public init(
    claim: @escaping @Sendable (MachineID, SessionID, ToolCallID) async throws -> ExecClaim,
    connect: @escaping @Sendable (ExecID) async throws -> any FrameTransport,
    status: @escaping @Sendable (ExecID) async throws -> ExecRecord?,
    mintScript: @escaping @Sendable (MachineID, SessionID, String) async throws -> ExecRecord,
    kill: @escaping @Sendable (ExecID) async throws -> Void,
  ) {
    self.claim = claim
    self.connect = connect
    self.status = status
    self.mintScript = mintScript
    self.kill = kill
  }
}

enum RosterTool: String, CaseIterable {
  case read
  case write
  case edit
  case grep
  case find
  case exec
  case machines
  case templates
  case observe
  case timer
  case cancel
  case query
  case sendMessage = "send_message"
  case request
  case report
  case createSession = "create_session"
  case setTitle = "set_title"
  case generateImage = "generate_image"
  case manipulateUI = "manipulate_ui"
  case runScript = "run_script"
}

public struct ToolExecutor: Sendable {
  let owner: any ToolOwnerClient
  let credentials: CredentialResolver
  let completionCatalog: (@Sendable () async throws -> ProviderCatalog)?
  let scripts: Scripts?

  public init(
    owner: any ToolOwnerClient,
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

func renderedFailure(_ error: ToolRunError) -> String {
  guard case let .object(fields) = error.payload else { return "tool failed" }
  var text = ""
  if case let .string(code)? = fields["code"] { text += "\(code): " }
  if case let .string(message)? = fields["message"] { text += message }
  if case let .string(hint)? = fields["hint"] { text += " (\(hint))" }
  if case let .string(token)? = fields["token"] { text += " [current token: \(token)]" }
  return text
}

extension ToolExecutor {
  func refuseUnlessLive(_ session: SessionID) async throws { try await owner.refuseUnlessLive(session) }
  func spawn(_ caller: SessionID, _ call: ToolCallID, _ order: SpawnOrder) async throws -> Spawned { try await owner.spawn(caller, call, order) }
  func sendMessage(_ caller: SessionID, _ call: ToolCallID, _ arguments: SendMessageArguments) async throws -> ToolResultPayload { try await owner.sendMessage(caller, call, arguments) }
  func request(_ caller: SessionID, _ call: ToolCallID, _ arguments: RequestArguments) async throws -> ToolResultPayload { try await owner.request(caller, call, arguments) }
  func setTags(_ caller: SessionID, of target: SessionID, to tags: [String]) async throws { try await owner.setTags(caller, of: target, to: tags) }
  func control(_ verb: SessionControl.Verb, _ caller: SessionID, of target: SessionID, force: Bool = false) async throws { try await owner.control(verb, caller, of: target, force: force) }
}
