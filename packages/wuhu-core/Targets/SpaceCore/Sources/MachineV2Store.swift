#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import GRDB
import struct OperationClient.ClientRecord
import struct OperationClient.OperationClaim
import struct OperationClient.OperationOwner
import protocol OperationClient.OperationStore
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.WriteRequest
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

@Selection private struct V2Capacity {
  var active: Bool
  var ownerScope: String
  var machineID: String
  var reservedBytes: Int
  var grp: String
}

public struct StoredMachineV2Operation: Sendable {
  public let owner: OperationOwner
  public let record: ClientRecord
}

public struct SpaceOperationStore: OperationStore {
  let space: Space
  let group: GroupID
  let key: SymmetricKey
  let problemsGroup: GroupID
  public func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await space.v2Lookup(owner, group: group, key: key) }
  public func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await space.v2Claim(owner, record: record, group: group, key: key) }
  public func read(_ id: UUID) async throws -> ClientRecord { try await space.v2Read(id, group: group, key: key) }
  public func transaction(_ id: UUID, _ update: @escaping @Sendable (inout ClientRecord) throws -> Void) async throws -> ClientRecord { try await space.v2Update(id, group: group, problemsGroup: problemsGroup, key: key, update: update) }
}

extension Space {
  /// The caller supplies a durable 256-bit key; losing it is a typed store failure, never plaintext recovery.
  public func machineV2Store(group: GroupID, key: SymmetricKey, problemsGroup: GroupID?) throws -> SpaceOperationStore {
    guard key.bitCount == 256, let problemsGroup else { throw OperationError(.storeUnavailable, message: "Machine v2 needs a durable key and explicit problems group") }
    return .init(space: self, group: group, key: key, problemsGroup: problemsGroup)
  }

  func v2Lookup(_ owner: OperationOwner, group: GroupID, key: SymmetricKey) async throws -> ClientRecord? {
    try await writer.read { db in
      guard let row = try MachineV2OperationRow.where({ $0.grp.eq(group.rawValue) && $0.ownerScope.eq(owner.scope) && $0.invocationKey.eq(owner.key) }).fetchOne(db) else { return nil }
      return try V2Records.load(row, key: key, in: db)
    }
  }

  func v2Read(_ id: UUID, group: GroupID, key: SymmetricKey) async throws -> ClientRecord {
    try await writer.read { db in try V2Records.load(V2Records.row(id, group: group, in: db), key: key, in: db) }
  }

  func v2Claim(_ owner: OperationOwner, record: ClientRecord, group: GroupID, key: SymmetricKey) async throws -> OperationClaim {
    guard record.description.limits.isValid, record.description.limits.bufferBytes <= 64 * 1024 * 1024,
          !owner.scope.isEmpty, !owner.key.isEmpty, owner.scope.utf8.count <= 1024, owner.key.utf8.count <= 1024 else { throw OperationError(.invalidInput) }
    guard try JSONEncoder().encode(record.start).count <= record.description.limits.inputBytes else { throw OperationError(.inputTooLarge) }
    let now = dateGen.now; let stamp = SQLiteDateFormat.string(from: now)
    return try await writer.write { db in
      if try V2Maintenance.due("receipts/" + group.rawValue, now: now, in: db) {
        let cutoff = SQLiteDateFormat.string(from: now.addingTimeInterval(-7 * 86400))
        let expired = try MachineV2RetentionRow.where { $0.grp.eq(group.rawValue) && $0.kind.eq("operation") && $0.expiredAt.lt(cutoff) }.fetchAll(db)
        for entry in expired {
          try MachineV2OperationRow.where { $0.id.eq(entry.id) && !$0.active }.delete().execute(db)
          try MachineV2RetentionRow.where { $0.id.eq(entry.id) }.delete().execute(db)
        }
      }
      if let row = try MachineV2OperationRow.where({ $0.grp.eq(group.rawValue) && $0.ownerScope.eq(owner.scope) && $0.invocationKey.eq(owner.key) }).fetchOne(db) {
        let prior = try V2Records.load(row, key: key, in: db)
        guard try prior.machine == record.machine && prior.start.canonicalData() == record.start.canonicalData() else { throw OperationError(.invocationConflict, operation: prior.id) }
        return .init(record: prior, dispatch: false)
      }
      let rows = try MachineV2OperationRow.where { ($0.grp.eq(group.rawValue) || $0.machineID.eq(record.machine)) && ($0.active || $0.reservedBytes.gt(0)) }.select { V2Capacity.Columns(active: $0.active, ownerScope: $0.ownerScope, machineID: $0.machineID, reservedBytes: $0.reservedBytes, grp: $0.grp) }.fetchAll(db)
      let active = rows.filter { $0.active && $0.grp == group.rawValue }
      let machineRows = rows.filter { $0.machineID == record.machine }
      let channels = record.description.kinds.first(where: { $0.name == record.start.kind }).map { $0.inputChannels + $0.outputChannels } ?? []
      var reservation = 0
      for channel in channels {
        guard channel.windowBytes > 0, channel.windowBytes <= record.description.limits.bufferBytes - reservation else { throw OperationError.capacityExceeded("bufferBytes", used: reservation, limit: record.description.limits.bufferBytes, requested: channel.windowBytes) }
        reservation += channel.windowBytes
      }
      guard active.count < 4096 else { throw OperationError.capacityExceeded("groupActiveOperations", used: active.count, limit: 4096) }
      let owned = active.filter { $0.ownerScope == owner.scope }.count
      guard owned < 8 else { throw OperationError.capacityExceeded("callerActiveOperations", used: owned, limit: 8) }
      let reserved = machineRows.reduce(0) { $0 + $1.reservedBytes }
      guard reserved + reservation <= record.description.limits.bufferBytes else { throw OperationError.capacityExceeded("machineBufferBytes", used: reserved, limit: record.description.limits.bufferBytes, requested: reservation) }
      guard try MachineV2OperationRow.where({ $0.id.eq(record.id.uuidString) }).fetchOne(db) == nil else { throw OperationError(.operationExists, operation: record.id) }
      let digest = try V2Records.digest(record, key: key)
      let row = MachineV2OperationRow(id: record.id.uuidString, grp: group.rawValue, ownerScope: owner.scope, invocationKey: owner.key, machineID: record.machine, correlationID: record.correlation.uuidString, inputDigest: digest, dispatchConsumed: true, record: "", active: true, reservedBytes: reservation, createdAt: stamp)
      try V2Records.save(record, row: row, key: key, stamp: stamp, in: db)
      return .init(record: record, dispatch: true)
    }
  }

  func v2Update(_ id: UUID, group: GroupID, problemsGroup: GroupID, key: SymmetricKey, update: @escaping @Sendable (inout ClientRecord) throws -> Void) async throws -> ClientRecord {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    return try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      let row = try V2Records.row(id, group: group, in: db)
      var record = try V2Records.load(row, key: key, in: db)
      try update(&record)
      guard record.id.uuidString == row.id, record.machine == row.machineID, try V2Records.digest(record, key: key) == row.inputDigest else { throw OperationError(.invocationConflict) }
      try V2Records.save(record, row: row, key: key, stamp: stamp, in: db)
      if let code = record.snapshot?.verdict?.error?.code, [.invalidResponse, .invalidOffset, .offsetExpired].contains(code) {
        _ = try V2Problems.record(group: problemsGroup, traceGroup: group, invariant: 13, code: code, incident: id.uuidString, correlation: record.correlation, stamp: stamp, in: db, pending: &pending)
      }
      return record
    }
  }

  public func machineV2HasEncryptedState() async throws -> Bool {
    try await writer.read { db in
      try MachineV2KeyCheckRow.all.fetchOne(db) != nil || MachineV2OperationRow.all.fetchOne(db) != nil
        || MachineV2ChannelRow.all.fetchOne(db) != nil || MachineV2OutputRow.all.fetchOne(db) != nil
    }
  }

  public func validateMachineV2Key(_ key: SymmetricKey) async throws {
    guard key.bitCount == 256 else { throw OperationError(.storeUnavailable) }
    try await writer.write { db in
      let context = "machine-v2-store-key"
      if let check = try MachineV2KeyCheckRow.where({ $0.id.eq(context) }).fetchOne(db) {
        let value: String = try V2Records.unseal(check.sealed, key: key, context: context)
        guard value == context else { throw OperationError(.storeUnavailable) }
      }
      for row in try MachineV2OperationRow.all.fetchAll(db) { _ = try V2Records.load(row, key: key, in: db) }
      if try MachineV2KeyCheckRow.where({ $0.id.eq(context) }).fetchOne(db) == nil {
        let row = MachineV2KeyCheckRow(id: context, sealed: try V2Records.seal(context, key: key, context: context))
        try MachineV2KeyCheckRow.insert { row }.execute(db)
      }
    }
  }

  public func machineV2RecoveryGroups() async throws -> Set<GroupID> {
    try await writer.read { db in Set(try MachineV2OperationRow.all.select { $0.grp }.fetchAll(db).map { GroupID(rawValue: $0) }) }
  }

  public func machineV2Recovery(group: GroupID, key: SymmetricKey) async throws -> [StoredMachineV2Operation] {
    try await writer.read { db in try MachineV2OperationRow.where { $0.grp.eq(group.rawValue) }.fetchAll(db).map { .init(owner: .init(scope: $0.ownerScope, key: $0.invocationKey), record: try V2Records.load($0, key: key, in: db)) } }
  }
}

private enum V2Records {
  static func digest(_ record: ClientRecord, key: SymmetricKey) throws -> String {
    let bytes = try record.start.canonicalData()
    return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key)).base64EncodedString()
  }

  static func row(_ id: UUID, group: GroupID, in db: Database) throws -> MachineV2OperationRow {
    guard let row = try MachineV2OperationRow.where({ $0.id.eq(id.uuidString) && $0.grp.eq(group.rawValue) }).fetchOne(db) else { throw OperationError(.unknownOperation, operation: id) }; return row
  }

  static func seal<T: Encodable>(_ value: T, key: SymmetricKey, context: String) throws -> String {
    guard key.bitCount == 256 else { throw OperationError(.storeUnavailable) }
    let box = try AES.GCM.seal(JSONEncoder().encode(value), using: key, authenticating: Data(context.utf8))
    guard let combined = box.combined else { throw OperationError(.storeUnavailable) }
    return combined.base64EncodedString()
  }

  static func unseal<T: Decodable>(_ value: String, key: SymmetricKey, context: String) throws -> T {
    do {
      guard let bytes = Data(base64Encoded: value) else { throw OperationError(.storeUnavailable) }
      return try JSONDecoder().decode(T.self, from: AES.GCM.open(.init(combined: bytes), using: key, authenticating: Data(context.utf8)))
    } catch { throw OperationError(.storeUnavailable, message: "Encrypted operation record is unavailable") }
  }

  static func load(_ row: MachineV2OperationRow, key: SymmetricKey, in db: Database) throws -> ClientRecord {
    var record: ClientRecord = try unseal(row.record, key: key, context: row.grp + row.id)
    for channel in try MachineV2ChannelRow.where({ $0.operationID.eq(row.id) }).fetchAll(db) {
      guard let committed = UInt64(channel.committed), let accepted = UInt64(channel.accepted) else { throw OperationError(.storeUnavailable) }
      record.committed[channel.name] = .init(rawValue: committed); record.accepted[channel.name] = .init(rawValue: accepted)
      if let pending = channel.pending { record.pendingInputs[channel.name] = try unseal(pending, key: key, context: row.grp + channel.id) }
    }
    for output in try MachineV2OutputRow.where({ $0.operationID.eq(row.id) }).order(by: { $0.sequence }).fetchAll(db) {
      let payload: ChannelPayload = try unseal(output.payload, key: key, context: row.grp + output.id)
      record.output[output.channel, default: []].append(payload)
    }
    return record
  }

  static func save(_ record: ClientRecord, row original: MachineV2OperationRow, key: SymmetricKey, stamp: String, in db: Database) throws {
    var row = original; var metadata = record
    metadata.committed = [:]; metadata.accepted = [:]; metadata.pendingInputs = [:]; metadata.output = [:]
    row.record = try seal(metadata, key: key, context: row.grp + row.id)
    row.active = record.snapshot?.verdict == nil && record.unknown == nil
    let output = record.output.values.flatMap { $0 }.reduce(0) { $0 + $1.byteCount }
    let input = record.pendingInputs.values.reduce(0) { $0 + $1.payload.byteCount }
    row.reservedBytes = row.active ? record.outputCapacity + record.inputCapacity : output + input
    if !row.active {
      if try MachineV2RetentionRow.where({ $0.id.eq(row.id) }).fetchOne(db) == nil {
        let retention = MachineV2RetentionRow(id: row.id, grp: row.grp, kind: "operation", expiredAt: stamp)
        try MachineV2RetentionRow.insert { retention }.execute(db)
      }
    }
    let inputs = record.description.kinds.first(where: { $0.name == record.start.kind })?.inputChannels ?? []
    for (name, pending) in record.pendingInputs {
      guard let channel = inputs.first(where: { $0.name == name }) else { throw OperationError(.unknownChannel, operation: record.id) }
      let limit = min(channel.windowBytes, 64 * 1024)
      guard pending.payload.byteCount <= limit else { throw OperationError.capacityExceeded("pendingInputBytes", used: pending.payload.byteCount, limit: limit, operation: record.id) }
    }
    guard output <= record.outputCapacity else { throw OperationError.capacityExceeded("outputBytes", used: output, limit: record.outputCapacity, operation: record.id) }
    guard input <= record.inputCapacity else { throw OperationError.capacityExceeded("inputBytes", used: input, limit: record.inputCapacity, operation: record.id) }
    try MachineV2OperationRow.upsert { row }.execute(db)
    try MachineV2ChannelRow.where { $0.operationID.eq(row.id) }.delete().execute(db)
    try MachineV2OutputRow.where { $0.operationID.eq(row.id) }.delete().execute(db)
    let names = Set(record.committed.keys).union(record.accepted.keys).union(record.pendingInputs.keys)
    for name in names {
      let id = row.id + "/" + name
      let pending = try record.pendingInputs[name].map { try seal($0, key: key, context: row.grp + id) }
      let channel = MachineV2ChannelRow(id: id, operationID: row.id, name: name, committed: String(record.committed[name]?.rawValue ?? 0), accepted: String(record.accepted[name]?.rawValue ?? 0), pending: pending)
      try MachineV2ChannelRow.insert { channel }.execute(db)
    }
    for (channel, chunks) in record.output {
      for (sequence, payload) in chunks.enumerated() {
        let id = row.id + "/" + channel + "/" + String(sequence)
        let output = MachineV2OutputRow(id: id, operationID: row.id, channel: channel, sequence: sequence, payload: try seal(payload, key: key, context: row.grp + id))
        try MachineV2OutputRow.insert { output }.execute(db)
      }
    }
  }
}
