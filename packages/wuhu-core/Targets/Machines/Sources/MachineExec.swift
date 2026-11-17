import JSONValue
import struct MachineContract.ExecID
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import MachinesContract
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.WriteReceipt
import SessionDomain
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

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
