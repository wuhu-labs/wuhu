import struct Credentials.CredentialResolver
import Foundation
import JSONValue
import protocol MachineChannel.FrameTransport
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import SessionDomain
import SpaceCore
import SpaceTools
import struct WuhuAI.ToolCall

// A model-facing failure: rendered into the transcript as a typed tool
// failure, never thrown past the executor.
struct ToolProblem: Error {
  var message: String

  init(_ message: String) {
    self.message = message
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
  case cancelObservation = "cancel_observation"
  case cancelTimer = "cancel_timer"
  case query
  case sendMessage = "send_message"
  case request
  case report
  case createSession = "create_session"
  case setTitle = "set_title"
  case generateImage = "generate_image"
  case manipulateUI = "manipulate_ui"
  case runScript = "run_script"
  case stopScript = "stop_script"
}

public struct ToolExecutor: Sendable {
  let space: Space
  let machines: MachineSeam?
  let execBackend: ExecBackend?
  let resolveModelExecutor: (@Sendable (_ provider: String, _ model: String, _ effort: String?) async throws -> SessionExecutor)?
  let credentials: CredentialResolver
  let scripts: Scripts?
  let control: SessionControl?

  public init(
    space: Space,
    machines: MachineSeam? = nil,
    exec: ExecBackend? = nil,
    resolveModelExecutor: (@Sendable (String, String, String?) async throws -> SessionExecutor)? = nil,
    credentials: CredentialResolver = .unavailable,
    scripts: Scripts? = nil,
    control: SessionControl? = nil,
  ) {
    self.space = space
    self.machines = machines
    execBackend = exec
    self.resolveModelExecutor = resolveModelExecutor
    self.credentials = credentials
    self.scripts = scripts
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
    } catch let problem as ToolProblem {
      return .failure(.init(message: problem.message))
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
      return try await sendMessage(session, callID, decoded(SendMessageArguments.self, call))
    case .request:
      return try await request(session, callID, decoded(RequestArguments.self, call))
    case .report:
      return try await report(session, callID, decoded(ReportArguments.self, call))
    case .createSession:
      return try await createSession(session, callID, decoded(CreateSessionArguments.self, call))
    case .setTitle:
      return try await setTitle(session, decoded(SetTitleArguments.self, call))
    case .generateImage:
      return try await generateImage(session, callID, decoded(GenerateImageArguments.self, call), state: state)
    case .manipulateUI:
      return try await manipulateUI(session, decoded(ManipulateUIArguments.self, call))
    case .runScript:
      return try await runScript(session, decoded(RunScriptArguments.self, call))
    case .stopScript:
      return try await stopScript(session, decoded(StopScriptArguments.self, call))
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

func renderedFailure(_ error: ToolRunError) -> String {
  guard case let .object(fields) = error.payload else { return "tool failed" }
  var text = ""
  if case let .string(code)? = fields["code"] { text += "\(code): " }
  if case let .string(message)? = fields["message"] { text += message }
  if case let .string(hint)? = fields["hint"] { text += " (\(hint))" }
  if case let .string(token)? = fields["token"] { text += " [current token: \(token)]" }
  return text
}
