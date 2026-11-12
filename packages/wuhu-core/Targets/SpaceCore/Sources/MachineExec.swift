import JSONValue
import struct MachineContract.ExecID
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.WriteReceipt
import SessionDomain
import struct SpaceContract.GroupID
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
}

public enum MachineExecReply: Codable, Sendable {
  case finished(ExecFinished)
}

public enum BoxPurpose: Hashable, Codable, Sendable {
  case start, control, output(String), input, fileInput(channel: String), stop, terminal(String)
}

public enum BoxTag: Hashable, Codable, Sendable {
  case describe
  case operation(UUID, BoxPurpose)
}

public enum BoxExchange: Sendable {
  case describe
  case start(MachineExec)
  case startFile(UUID, StartRequest)
  case poll(UUID, channel: String?, after: UInt64, holdMs: Int, terminal: UUID?, limit: Int)
  case stop(UUID, String)
  case input(UUID, MachinePointer, end: Bool)
  case fileInput(UUID, MachinePointer, end: Bool)
}

public struct BoxSnapshot: Sendable {
  public var snapshot: OperationSnapshot
  public var output: MachinePointer?
  public var tail: Data

  public init(snapshot: OperationSnapshot, output: MachinePointer? = nil, tail: Data = Data()) {
    precondition(snapshot.payload == nil)
    self.snapshot = snapshot; self.output = output; self.tail = tail
  }
}

public enum BoxAnswer: Sendable {
  case description(MachineDescription)
  case snapshot(BoxSnapshot)
  case input(WriteReceipt)
  case box(OperationError)
  case transport(OperationError)
  case preparation(OperationError)
}

public enum BoxSocket: Socket {
  public struct Opening: Sendable {
    public var connection: UUID
    public var pubkey: String
    public var streams: Int
    public init(connection: UUID, pubkey: String, streams: Int) { self.connection = connection; self.pubkey = pubkey; self.streams = streams }
  }

  public struct Outgoing: Sendable {
    public var tag: BoxTag
    public var exchange: BoxExchange
    public init(tag: BoxTag, exchange: BoxExchange) { self.tag = tag; self.exchange = exchange }
  }

  public struct Incoming: Sendable {
    public var tag: BoxTag
    public var answer: BoxAnswer
    public init(tag: BoxTag, answer: BoxAnswer) { self.tag = tag; self.answer = answer }
  }
}

public enum ExecStream: Socket {
  public struct Opening: Sendable {
    public var exec: MachineExec
    public var nonce: UUID
    public init(exec: MachineExec, nonce: UUID) { self.exec = exec; self.nonce = nonce }
  }

  public enum Incoming: Sendable {
    case stdin(MachinePointer)
    case eof(UInt64)
    case kill
    case consumed(Int)
  }

  public enum Outgoing: Sendable {
    case accepted(UInt64)
    case output(MachinePointer, cursor: Int)
    case exit(ExecFinished)
  }
}
