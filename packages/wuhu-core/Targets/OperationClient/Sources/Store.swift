#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.KindDescriptor
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

/// One poll answer's output, retained until its consumer acknowledges it. `sequence` orders every chunk of one operation across
/// its channels in arrival order; it never repeats.
public struct OutputChunk: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let channel: String
  public let from: Offset
  public let payload: ChannelPayload
  public init(sequence: UInt64, channel: String, from: Offset, payload: ChannelPayload) {
    self.sequence = sequence; self.channel = channel; self.from = from; self.payload = payload
  }

  public var through: Offset { Offset(rawValue: from.rawValue + UInt64(payload.count)) }
}

/// The durable state of one operation. `output` is retained output in arrival order: `read` loads it and `save` appends at most
/// one chunk, so a store never rewrites retained output.
public struct ClientRecord: Codable, Sendable {
  public let id: UUID
  public let correlation: UUID
  public let machine: String
  public let start: StartRequest
  public let description: MachineDescription
  /// Output offsets taken from the machine (durable here, so acknowledged there).
  public var committed: [String: Offset] = [:]
  /// Output offsets the consumer acknowledged: retained output starts here. Output dropped by `discard` never counts.
  public var consumed: [String: Offset] = [:]
  /// Input offsets the machine accepted.
  public var accepted: [String: Offset] = [:]
  /// At most one unaccepted write per input channel, at its `accepted` offset.
  public var pendingInputs: [String: WriteRequest] = [:]
  public var output: [OutputChunk] = []
  public var nextSequence: UInt64 = 0
  public var snapshot: OperationSnapshot?
  /// Why the operation ended without terminal evidence, or with evidence that broke the protocol. Final.
  public var diagnostic: OperationError?
  public var stopReason: String?
  /// The consumer gave up on the output: it is taken from the machine and dropped.
  public var discard = false
  /// The machine took the terminal acknowledgement on every output channel: it may drop the operation.
  public var terminalAcknowledged = false
  /// The consumer's own durable state, kept with the record and never read here.
  public var consumer: JSONValue?

  public init(id: UUID, correlation: UUID, machine: String, start: StartRequest, description: MachineDescription) {
    self.id = id; self.correlation = correlation; self.machine = machine; self.start = start; self.description = description
  }

  enum CodingKeys: String, CodingKey {
    case id, correlation, machine, start, description, committed, consumed, accepted, pendingInputs, output, nextSequence, snapshot
    case diagnostic = "unknown", stopReason, discard, terminalAcknowledged, consumer
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    correlation = try c.decode(UUID.self, forKey: .correlation)
    machine = try c.decode(String.self, forKey: .machine)
    start = try c.decode(StartRequest.self, forKey: .start)
    description = try c.decode(MachineDescription.self, forKey: .description)
    committed = try c.decodeIfPresent([String: Offset].self, forKey: .committed) ?? [:]
    consumed = try c.decodeIfPresent([String: Offset].self, forKey: .consumed) ?? [:]
    accepted = try c.decodeIfPresent([String: Offset].self, forKey: .accepted) ?? [:]
    pendingInputs = try c.decodeIfPresent([String: WriteRequest].self, forKey: .pendingInputs) ?? [:]
    output = (try? c.decodeIfPresent([OutputChunk].self, forKey: .output)) ?? []
    nextSequence = try c.decodeIfPresent(UInt64.self, forKey: .nextSequence) ?? 0
    snapshot = try c.decodeIfPresent(OperationSnapshot.self, forKey: .snapshot)
    diagnostic = try c.decodeIfPresent(OperationError.self, forKey: .diagnostic)
    stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
    discard = try c.decodeIfPresent(Bool.self, forKey: .discard) ?? false
    terminalAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .terminalAcknowledged) ?? false
    consumer = try c.decodeIfPresent(JSONValue.self, forKey: .consumer)
  }

  public var kind: KindDescriptor? { description.kinds.first { $0.name == start.kind } }
  public var outputChannels: [ChannelDescriptor] { kind?.outputChannels ?? [] }
  public var inputChannels: [ChannelDescriptor] { kind?.inputChannels ?? [] }
  /// The machine acknowledged the terminal record: nothing about this operation is left to fetch.
  public var retired: Bool { snapshot?.verdict != nil && terminalAcknowledged }
  /// Still has work for its driver: not retired, not concluded by a diagnostic.
  public var live: Bool { !retired && diagnostic == nil }
  /// Every output channel was taken through its final offset. A verdict can come before a channel's final offset: the
  /// machine still drains that channel's tail.
  public var drained: Bool {
    guard let snapshot, snapshot.verdict != nil else { return false }
    return outputChannels.allSatisfy { channel in snapshot.finalOffsets[channel.name].map { (committed[channel.name] ?? .zero) >= $0 } ?? false }
  }

  public func retainedBytes(_ channel: String) -> Int {
    output.reduce(0) { $1.channel == channel ? $0 + $1.payload.byteCount : $0 }
  }

  /// Bytes the machine may hold for this operation: every channel's window, within the machine's buffer.
  public var reservation: Int { capacity(inputChannels) + capacity(outputChannels) }
  private func capacity(_ channels: [ChannelDescriptor]) -> Int {
    channels.reduce(0) { total, channel in total + min(max(0, channel.windowBytes), max(0, description.limits.bufferBytes - total)) }
  }
}

public struct OperationClaim: Sendable {
  public let record: ClientRecord
  public let dispatch: Bool
  public init(record: ClientRecord, dispatch: Bool) { self.record = record; self.dispatch = dispatch }
}

public struct StoredOperation: Sendable {
  public let owner: OperationOwner
  public let id: UUID
  /// The record, or why the store cannot read it.
  public let record: Result<ClientRecord, OperationError>
  public init(owner: OperationOwner, record: ClientRecord) { self.owner = owner; id = record.id; self.record = .success(record) }
  public init(owner: OperationOwner, id: UUID, damage: OperationError) { self.owner = owner; self.id = id; record = .failure(damage) }
}

/// Durable operation state, one record per owner. Only the operation's driver writes a record after its claim.
public protocol OperationStore: Sendable {
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord?
  /// Creates the owner's record, or returns its existing one with `dispatch` false. A different machine or start is
  /// `invocationConflict`.
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim
  /// The record with its retained output.
  func read(_ id: UUID) async throws -> ClientRecord
  /// Every record that is still `live`, with retained output; one that cannot be read is listed with why, not thrown.
  func live() async throws -> [StoredOperation]
  /// Ends a live record nobody can read or keep any more: it stays, no longer live, and holds nothing.
  func setAside(_ id: UUID) async throws
  /// Persists the record's state and cursors, ignoring `output` except `chunk`, which must be its last element: one append.
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws
  /// Persists the record's state and deletes the retained chunks with these sequences.
  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws
}

public actor MemoryOperationStore: OperationStore {
  var owners: [OperationOwner: UUID] = [:]
  var records: [UUID: ClientRecord] = [:]
  public init() {}

  public func lookup(_ owner: OperationOwner) -> ClientRecord? { owners[owner].flatMap { records[$0] } }

  public func claim(_ owner: OperationOwner, record: ClientRecord) throws -> OperationClaim {
    if let id = owners[owner], let prior = records[id] {
      guard try prior.machine == record.machine && prior.start.canonicalData() == record.start.canonicalData() else { throw OperationError(.invocationConflict, operation: id) }
      return .init(record: prior, dispatch: false)
    }
    guard records[record.id] == nil else { throw OperationError(.operationExists, operation: record.id) }
    owners[owner] = record.id; records[record.id] = record
    return .init(record: record, dispatch: true)
  }

  public func read(_ id: UUID) throws -> ClientRecord {
    guard let record = records[id] else { throw OperationError(.unknownOperation, operation: id) }; return record
  }

  public func live() -> [StoredOperation] {
    owners.compactMap { owner, id in records[id].flatMap { $0.live ? StoredOperation(owner: owner, record: $0) : nil } }
  }

  public func setAside(_ id: UUID) throws {
    guard var record = records[id] else { throw OperationError(.unknownOperation, operation: id) }
    record.diagnostic = record.diagnostic ?? OperationError(.storeUnavailable, message: "Operation record set aside", operation: id)
    record.output = []; record.pendingInputs = [:]; record.discard = true
    records[id] = record
  }

  public func save(_ record: ClientRecord, appending chunk: OutputChunk?) throws {
    let prior = try read(record.id)
    var next = record
    next.output = prior.output + (chunk.map { [$0] } ?? [])
    records[record.id] = next
  }

  public func trim(_ record: ClientRecord, removing sequences: [UInt64]) throws {
    let prior = try read(record.id)
    var next = record
    next.output = prior.output.filter { !sequences.contains($0.sequence) }
    records[record.id] = next
  }
}
