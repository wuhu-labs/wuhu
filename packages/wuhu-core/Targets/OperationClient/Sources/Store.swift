#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.WriteRequest

public struct OperationOwner: Hashable, Codable, Sendable {
  public let scope: String
  public let key: String
  public init(scope: String, key: String) { self.scope = scope; self.key = key }
}

public struct ClientRecord: Codable, Sendable {
  public let id: UUID
  public let correlation: UUID
  public let machine: String
  public let start: StartRequest
  public let description: MachineDescription
  public var committed: [String: Offset] = [:]
  public var accepted: [String: Offset] = [:]
  public var pendingInputs: [String: WriteRequest] = [:]
  public var output: [String: [ChannelPayload]] = [:]
  public var snapshot: OperationSnapshot?
  public var evidenceGeneration: UInt64?
  public var unknown: OperationError?
  public var stopReason: String?
  public var callerRemainingMs: Int?
  public init(id: UUID, correlation: UUID, machine: String, start: StartRequest, description: MachineDescription) {
    self.id = id; self.correlation = correlation; self.machine = machine; self.start = start; self.description = description
  }

  mutating func markEvidence() throws {
    let (next, overflow) = (evidenceGeneration ?? 0).addingReportingOverflow(1)
    guard !overflow else { throw OperationError(.capacityExceeded) }
    evidenceGeneration = next
  }
}

public struct OperationClaim: Sendable {
  public let record: ClientRecord
  public let dispatch: Bool
  public init(record: ClientRecord, dispatch: Bool) { self.record = record; self.dispatch = dispatch }
}

public protocol OperationStore: Sendable {
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord?
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim
  func read(_ id: UUID) async throws -> ClientRecord
  func transaction(_ id: UUID, _ update: @Sendable (inout ClientRecord) throws -> Void) async throws -> ClientRecord
}

public actor MemoryOperationStore: OperationStore {
  var owners: [OperationOwner: UUID] = [:]
  var records: [UUID: ClientRecord] = [:]
  let capacity: Int
  public init(capacity: Int = 4096) { precondition(capacity > 0); self.capacity = capacity }
  public func lookup(_ owner: OperationOwner) -> ClientRecord? { owners[owner].flatMap { records[$0] } }
  public func claim(_ owner: OperationOwner, record: ClientRecord) throws -> OperationClaim {
    if let id = owners[owner], let prior = records[id] {
      guard prior.machine == record.machine && prior.start == record.start else { throw OperationError(.invocationConflict, operation: id) }
      return .init(record: prior, dispatch: false)
    }
    guard records.count < capacity, records[record.id] == nil else { throw OperationError(.capacityExceeded) }
    owners[owner] = record.id; records[record.id] = record
    return .init(record: record, dispatch: true)
  }

  public func read(_ id: UUID) throws -> ClientRecord {
    guard let record = records[id] else { throw OperationError(.unknownOperation) }; return record
  }

  public func transaction(_ id: UUID, _ update: @Sendable (inout ClientRecord) throws -> Void) throws -> ClientRecord {
    var record = try read(id); try update(&record); records[id] = record; return record
  }
}
