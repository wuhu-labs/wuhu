import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.OperationSnapshot
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Table("machine_file_operations")
struct MachineFileOperation: Owned {
  var id: String
  @Column(as: MachineFile.JSONRepresentation.self) var request: MachineFile
  var state = "reserved"
  var worker: String?
  var stream: Int?
  var created: Int64
  var dispatched = false
  var delivered = false
  var stop: String?
  var inputReady = false
  @Column(as: [String: UInt64].JSONRepresentation.self) var inputOffsets: [String: UInt64] = [:]
  @Column(as: [ChannelDescriptor].JSONRepresentation.self) var inputChannels: [ChannelDescriptor] = []
  @Column(as: Set<String>.JSONRepresentation.self) var inputEnded: Set<String> = []
  @Column(as: [String: UInt64].JSONRepresentation.self) var offsets: [String: UInt64] = [:]
  @Column(as: [String: UInt64].JSONRepresentation.self) var offered: [String: UInt64] = [:]
  @Column(as: [String: UInt64].JSONRepresentation.self) var received: [String: UInt64] = [:]
  @Column(as: OperationSnapshot?.JSONRepresentation.self) var snapshot: OperationSnapshot?
  @Column(as: MachineFileFailure?.JSONRepresentation.self) var failure: MachineFileFailure?
  @Column(as: Set<String>.JSONRepresentation.self) var endedChannels: Set<String> = []
  @Column(as: Set<String>.JSONRepresentation.self) var terminalAcks: Set<String> = []
  @Column(as: [BoxPurpose: ExecFlight].JSONRepresentation.self) var flights: [BoxPurpose: ExecFlight] = [:]
}
