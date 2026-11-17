import struct MachineContract.ExecID
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import MachinesContract
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import SessionDomain
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Wuwei

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct MachineExec: Codable, Sendable, Equatable {
  public var id: String
  public var operation: UUID
  private var createdMilliseconds: Int64
  public var createdAt: Date {
    get { Date(timeIntervalSince1970: Double(createdMilliseconds) / 1000) }
    set { createdMilliseconds = Int64(newValue.timeIntervalSince1970 * 1000) }
  }

  public var group: GroupID
  public var caller: String?
  public var session: SessionID?
  public var toolCall: ToolCallID?
  public var script: String?
  public var attribution: StartRequest.Caller?
  public var argv: [String]
  public var stdin: Bool
  public var cwd: String
  public var env: [String: String]
  public var secrets: [String: String]
  public var window: Int
  public var maxOutput: Int?
  public var timeout: Double?

  public init(id: String, operation: UUID, createdAt: Date, group: GroupID, caller: String? = nil, session: SessionID? = nil, toolCall: ToolCallID? = nil, script: String? = nil, attribution: StartRequest.Caller? = nil, argv: [String] = [], stdin: Bool = false, cwd: String = "/", env: [String: String] = [:], secrets: [String: String] = [:], window: Int = 4 << 20, maxOutput: Int? = nil, timeout: Double? = nil) {
    self.id = id; self.operation = operation; self.createdMilliseconds = Int64(createdAt.timeIntervalSince1970 * 1000); self.group = group; self.caller = caller; self.session = session; self.toolCall = toolCall; self.script = script; self.attribution = attribution
    self.argv = argv; self.stdin = stdin; self.cwd = cwd; self.env = env; self.secrets = secrets; self.window = window; self.maxOutput = maxOutput; self.timeout = timeout
  }
}

public struct ExecFinished: Codable, Sendable {
  public var id: String
  public var status: ExitStatus?
  public var error: OperationError?
  public var tail: Data
  public var cursor: Int
  public var cut: Bool
  public var timedOut: ExecTimeout?

  public init(id: String, status: ExitStatus?, error: OperationError?, tail: Data, cursor: Int, cut: Bool, timedOut: ExecTimeout?) {
    self.id = id; self.status = status; self.error = error; self.tail = tail; self.cursor = cursor; self.cut = cut; self.timedOut = timedOut
  }
}

public enum MachineExecReply: Codable, Sendable {
  case finished(ExecFinished)
}

/// What a cell posts to a machine cell: the exec a tool call starts or hands back.
public enum MachineMail: Codable, Sendable {
  public static let kind = "MachineCell"

  case start(MachineExec, finished: Recipient<MachineExecReply>)
  case detach(String)
  case taken(String)
  case abandon(String)
}
