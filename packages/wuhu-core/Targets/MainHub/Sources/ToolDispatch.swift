import struct MachineContract.ExecID
import struct MachineContract.MachineID
import SessionDomain

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

// Creation committed, but its template or brief did not finish; the error names the session left behind.
public struct IncompleteSession: Error, Sendable {
  public static let code = "incompleteSession"
  public var id: SessionID
  public var message: String

  public init(id: SessionID, message: String) {
    self.id = id
    self.message = message
  }
}

public enum RosterTool: String, CaseIterable, Sendable {
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
  case manipulateUI = "manipulate_ui"
  case runScript = "run_script"
}

extension RosterTool {
  /// Whether a call of the tool runs to its end and answers with its own result when the task running it is cancelled. The five that reach a machine or a script — `grep`, `find`, `query`, `exec`, `run_script` — throw `CancellationError` where the cancellation reaches them instead, and their job answers the restart failure; a `grep` or a `find` already begun still finishes its page.
  public var finishesWhenCancelled: Bool {
    switch self {
    case .grep, .find, .query, .exec, .runScript: false
    default: true
    }
  }
}
