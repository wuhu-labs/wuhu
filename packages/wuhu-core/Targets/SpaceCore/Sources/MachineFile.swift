import JSONValue
import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct MachineFile: Codable, Sendable, Equatable {
  public var operation: UUID
  public var start: StartRequest

  public init(operation: UUID, start: StartRequest) {
    self.operation = operation; self.start = start
  }
}

public enum MachineFileFailure: Error, Codable, Sendable {
  case operation(OperationError)
  case rangeLost(offset: UInt64)
  case outcomeUnknown
}

public enum FileBulk: Socket {
  public struct Opening: Sendable {
    public var request: MachineFile
    public init(request: MachineFile) {
      self.request = request
    }
  }

  public enum Incoming: Sendable {
    case input(MachinePointer, end: Bool)
    case want(channel: String, offset: UInt64)
    case cancel
  }

  public enum Outgoing: Sendable {
    case started
    case ready(inputs: [ChannelDescriptor])
    case accepted(channel: String, offset: UInt64, end: Bool)
    case output(MachinePointer)
    case finished(Result<JSONValue, MachineFileFailure>)
  }
}
