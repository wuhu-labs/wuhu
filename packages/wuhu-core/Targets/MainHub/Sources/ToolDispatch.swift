import protocol MachineChannel.FrameTransport
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import SessionDomain
import struct SpaceCore.ExecClaim
import struct SpaceCore.ExecRecord

// A model-facing failure: rendered into the transcript as a typed tool
// failure, never thrown past the executor.
public struct ToolProblem: Error {
  public var message: String
  public var code: String?

  public init(_ message: String, code: String? = nil) {
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

public enum RosterTool: String, CaseIterable {
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
