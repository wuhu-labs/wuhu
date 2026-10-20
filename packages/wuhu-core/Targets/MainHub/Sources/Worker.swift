#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import struct WuhuAI.ToolCall

public enum WorkerInput: Sendable {
  case wake, interrupt, resume, reload, archived
}

public enum RevocationPolicy: Sendable {
  case whenSettled, cancel
}

public struct ScriptRunID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WorkerActivity: Sendable {
  public let scripts: [ScriptRunID: SessionID]

  public init(scripts: [ScriptRunID: SessionID]) {
    self.scripts = scripts
  }
}

public struct ScriptHandlerResult: Sendable {
  public let stateJSON: String
  public let wakes: [String]
  public init(stateJSON: String, wakes: [String]) {
    self.stateJSON = stateJSON
    self.wakes = wakes
  }
}

public struct ScriptHandlerInvocation: Sendable {
  public enum Input: Sendable {
    case rows(Rows)
    case timer(Date)
  }

  public let id: UUID
  public let path: String
  public let session: SessionID
  public let input: Input
  public let stateJSON: String?

  public init(id: UUID, path: String, session: SessionID, input: Input, stateJSON: String?) {
    self.id = id
    self.path = path
    self.session = session
    self.input = input
    self.stateJSON = stateJSON
  }
}

public protocol Worker: Sendable {
  func deliver(_ session: SessionID, _ input: WorkerInput) async throws
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool
  func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolOutcome
  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  func activity() async -> WorkerActivity
  func drain() async
  func shutdown() async
}
