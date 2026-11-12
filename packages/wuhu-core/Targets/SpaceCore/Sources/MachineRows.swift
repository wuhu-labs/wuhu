import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@Table("machine_presence")
struct MachinePresence: Owned, Equatable {
  var state = "lost"
  var observed: Int64 = 0
  var lease: Int64?
  var describeAt: Int64?
  var describeDeadline: Int64?
  var describeRetry: Int64 = 100
  var leaseMs = 60000
  var pollHoldMs: Int?
  var pollBytes: Int?
  var resultBytes: Int?
  var execStdoutWindow: Int?
  var execStderrWindow: Int?

  var runtime: MachineRuntime? {
    guard let pollHoldMs, let pollBytes, let resultBytes else { return nil }
    return MachineRuntime(leaseMs: leaseMs, pollHoldMs: pollHoldMs, pollBytes: pollBytes, resultBytes: resultBytes, execStdoutWindow: execStdoutWindow, execStderrWindow: execStderrWindow)
  }
}

struct MachineRuntime {
  var leaseMs: Int
  var pollHoldMs: Int
  var pollBytes: Int
  var resultBytes: Int
  var execStdoutWindow: Int?
  var execStderrWindow: Int?
}

@Table("machine_descriptions")
struct MachineDescriptionRow: Owned {
  @Column(as: MachineDescription.JSONRepresentation.self) var description: MachineDescription
}

@Selection struct MachinePresenceDeadlines {
  var lease: Int64?
  var describeAt: Int64?
  var describeDeadline: Int64?
}

@Selection struct MachineOperationDeadlines {
  var opened: Bool
  var created: Int64
  var stopAt: Int64?
  var answerAt: Int64?
  @Column(as: [BoxPurpose: ExecFlight].JSONRepresentation.self) var flights: [BoxPurpose: ExecFlight]
}

struct ExecFlight: Codable {
  var due: Int64
  var retry: Int64 = 100
  var waiting = true
}

@Table("machine_operations")
struct MachineOperation: Owned {
  var id: String
  var operation = ""
  var caller: String?
  var toolCall: String?
  var script: String?
  @Column(as: UUID?.JSONRepresentation.self) var stream: UUID?
  @Column(as: MachineExec.JSONRepresentation.self) var request: MachineExec
  @Column(as: Recipient<MachineExecReply>?.JSONRepresentation.self) var recipient: Recipient<MachineExecReply>?
  var state = "pendingStart"
  var opened = false
  var dispatched = false
  var background = false
  var delivered = false
  var created: Int64
  var stdout: UInt64 = 0
  var stderr: UInt64 = 0
  var stdin: UInt64 = 0
  var stdinEnded = false
  var cursor = 0
  var consumed = 0
  var tail = Data()
  var cut: Int?
  @Column(as: OperationSnapshot?.JSONRepresentation.self) var snapshot: OperationSnapshot?
  @Column(as: OperationError?.JSONRepresentation.self) var diagnostic: OperationError?
  var stop: String?
  var stopSent = false
  var stopAt: Int64?
  var answerAt: Int64?
  @Column(as: Set<String>.JSONRepresentation.self) var endedChannels: Set<String> = []
  @Column(as: Set<String>.JSONRepresentation.self) var terminalAcks: Set<String> = []
  @Column(as: [BoxPurpose: ExecFlight].JSONRepresentation.self) var flights: [BoxPurpose: ExecFlight] = [:]

  static var live: Where<Self> { all.where { $0.state.neq("retired") } }

  var terminal: Bool { state == "retired" }
  var drained: Bool {
    guard let snapshot, snapshot.verdict != nil else { return false }
    return ["stdout", "stderr"].allSatisfy { channel in
      snapshot.finalOffsets[channel].map { offset(channel) >= $0.rawValue } ?? false
    }
  }

  func offset(_ channel: String) -> UInt64 { channel == "stderr" ? stderr : stdout }
}
