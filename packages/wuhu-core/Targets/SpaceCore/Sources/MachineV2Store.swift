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
import struct OperationClient.OutputChunk
import struct OperationClient.StoredOperation
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.WriteRequest
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

/// One group's operations in the space database. The operation row holds sealed state and cursors; retained output is one
/// sealed row per chunk, inserted once and deleted on acknowledgement.
public struct SpaceOperationStore: OperationStore {
  let space: Space
  let group: GroupID
  let key: SymmetricKey
  let problemsGroup: GroupID
  public func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await space.v2Lookup(owner, group: group, key: key) }
  public func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await space.v2Claim(owner, record: record, group: group, key: key) }
  public func read(_ id: UUID) async throws -> ClientRecord { try await space.v2Read(id, group: group, key: key) }
  public func live() async throws -> [StoredOperation] { try await space.v2Live(group: group, key: key) }
  public func setAside(_ id: UUID) async throws { try await space.v2SetAside(id, group: group) }
  public func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws {
    try await space.v2Write(record, group: group, problemsGroup: problemsGroup, key: key) { row, db in
      guard let chunk else { return }
      guard record.output.last?.sequence == chunk.sequence else { throw OperationError(.invalidInput, operation: record.id) }
      let id = row.id + "/" + String(chunk.sequence)
      let output = try MachineV2OutputRow(id: id, operationID: row.id, channel: chunk.channel, sequence: Int(chunk.sequence), payload: V2Records.seal(chunk, key: key, context: row.grp + id))
      try MachineV2OutputRow.insert { output }.execute(db)
    }
  }

  public func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws {
    try await space.v2Write(record, group: group, problemsGroup: problemsGroup, key: key) { row, db in
      let ids = sequences.map { row.id + "/" + String($0) }
      try MachineV2OutputRow.where { $0.operationID.eq(row.id) && $0.id.in(ids) }.delete().execute(db)
    }
  }
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

  func v2Live(group: GroupID, key: SymmetricKey) async throws -> [StoredOperation] {
    try await writer.read { db in
      try MachineV2OperationRow.where { $0.grp.eq(group.rawValue) && $0.active }.fetchAll(db).map { row in
        let owner = OperationOwner(scope: row.ownerScope, key: row.invocationKey)
        // The key is authenticated already: a row that does not open is that row's damage, not the store's.
        do { return try StoredOperation(owner: owner, record: V2Records.load(row, key: key, in: db)) } catch let damage as OperationError {
          guard let id = UUID(uuidString: row.id) else { throw damage }
          return StoredOperation(owner: owner, id: id, damage: damage)
        }
      }
    }
  }

  /// Ends a live operation row nobody can read or keep: it stays for inspection, no longer live, holding no bytes.
  func v2SetAside(_ id: UUID, group: GroupID) async throws {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      var row = try V2Records.row(id, group: group, in: db)
      guard row.active else { return }
      row.active = false
      row.reservedBytes = 0
      try MachineV2OperationRow.upsert { row }.execute(db)
      try MachineV2OutputRow.where { $0.operationID.eq(row.id) }.delete().execute(db)
      if try MachineV2RetentionRow.where({ $0.id.eq(row.id) }).fetchOne(db) == nil {
        let retention = MachineV2RetentionRow(id: row.id, grp: row.grp, kind: "operation", expiredAt: stamp)
        try MachineV2RetentionRow.insert { retention }.execute(db)
      }
    }
  }

  func v2Claim(_ owner: OperationOwner, record: ClientRecord, group: GroupID, key: SymmetricKey) async throws -> OperationClaim {
    guard record.description.limits.isValid, record.description.limits.bufferBytes <= 64 * 1024 * 1024,
          !owner.scope.isEmpty, !owner.key.isEmpty, owner.scope.utf8.count <= 1024, owner.key.utf8.count <= 1024 else { throw OperationError(.invalidInput) }
    guard try JSONEncoder().encode(record.start).count <= record.description.limits.inputBytes else { throw OperationError(.inputTooLarge) }
    let now = dateGen.now; let stamp = SQLiteDateFormat.string(from: now)
    return try await writer.write { db in
      guard try MachineV2MemberRow.where({ $0.machineID.eq(record.machine) }).fetchOne(db) != nil else {
        throw OperationError(.unknownMachine)
      }
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
      let channels = record.description.kinds.first(where: { $0.name == record.start.kind }).map { $0.inputChannels + $0.outputChannels } ?? []
      var reservation = 0
      for channel in channels {
        guard channel.windowBytes > 0, channel.windowBytes <= record.description.limits.bufferBytes - reservation else { throw OperationError.capacityExceeded("bufferBytes", used: reservation, limit: record.description.limits.bufferBytes, requested: channel.windowBytes) }
        reservation += channel.windowBytes
      }
      // Admission is by bytes alone: the machine's buffer, shared by every group's operations on it.
      let reserved = try MachineV2OperationRow.where { $0.machineID.eq(record.machine) && ($0.active || $0.reservedBytes.gt(0)) }.select(\.reservedBytes).fetchAll(db).reduce(0, +)
      guard reserved + reservation <= record.description.limits.bufferBytes else { throw OperationError.capacityExceeded("machineBufferBytes", used: reserved, limit: record.description.limits.bufferBytes, requested: reservation) }
      guard try MachineV2OperationRow.where({ $0.id.eq(record.id.uuidString) }).fetchOne(db) == nil else { throw OperationError(.operationExists, operation: record.id) }
      let digest = try V2Records.digest(record, key: key)
      let row = MachineV2OperationRow(id: record.id.uuidString, grp: group.rawValue, ownerScope: owner.scope, invocationKey: owner.key, machineID: record.machine, correlationID: record.correlation.uuidString, inputDigest: digest, dispatchConsumed: true, record: "", active: true, reservedBytes: reservation, createdAt: stamp)
      try V2Records.writeState(record, row: row, key: key, stamp: stamp, in: db)
      return .init(record: record, dispatch: true)
    }
  }

  /// Persists the record's state and cursors, then `output`'s change to its retained rows, in one transaction.
  func v2Write(_ record: ClientRecord, group: GroupID, problemsGroup: GroupID, key: SymmetricKey, output: @escaping @Sendable (MachineV2OperationRow, Database) throws -> Void) async throws {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      let row = try V2Records.row(record.id, group: group, in: db)
      guard record.machine == row.machineID, try V2Records.digest(record, key: key) == row.inputDigest else { throw OperationError(.invocationConflict, operation: record.id) }
      try V2Records.writeState(record, row: row, key: key, stamp: stamp, in: db)
      try output(row, db)
      if let code = record.snapshot?.verdict?.error?.code, [.invalidResponse, .invalidOffset, .offsetExpired].contains(code) {
        _ = try V2Problems.record(group: problemsGroup, traceGroup: group, invariant: 13, code: code, incident: row.id, correlation: record.correlation, stamp: stamp, in: db, pending: &pending)
      }
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
      } else {
        // State written before the check existed: the key is the one any operation row's state opens with. A row that does
        // not open is that row's damage, left to its group's recovery.
        let rows = try MachineV2OperationRow.all.fetchAll(db)
        guard rows.isEmpty || rows.contains(where: { (try? V2Records.unseal($0.record, key: key, context: $0.grp + $0.id) as ClientRecord) != nil }) else {
          throw OperationError(.storeUnavailable, message: "Machine v2 key does not open the stored operations")
        }
        let row = try MachineV2KeyCheckRow(id: context, sealed: V2Records.seal(context, key: key, context: context))
        try MachineV2KeyCheckRow.insert { row }.execute(db)
      }
    }
  }

  /// Groups with live operations: the ones whose drivers boot resumes.
  public func machineV2RecoveryGroups() async throws -> Set<GroupID> {
    try await writer.read { db in try Set(MachineV2OperationRow.where(\.active).select(\.grp).fetchAll(db).map { GroupID(rawValue: $0) }) }
  }
}

enum V2Records {
  static func digest(_ record: ClientRecord, key: SymmetricKey) throws -> String {
    let bytes = try record.start.canonicalData()
    return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key)).base64EncodedString()
  }

  static func row(_ id: UUID, group: GroupID, in db: Database) throws -> MachineV2OperationRow {
    guard let row = try MachineV2OperationRow.where({ $0.id.eq(id.uuidString) && $0.grp.eq(group.rawValue) }).fetchOne(db) else { throw OperationError(.unknownOperation, operation: id) }
    return row
  }

  static func seal(_ value: some Encodable, key: SymmetricKey, context: String) throws -> String {
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
    for output in try MachineV2OutputRow.where({ $0.operationID.eq(row.id) }).order(by: \.sequence).fetchAll(db) {
      if output.id == legacyOutputID(row.id, channel: output.channel, sequence: output.sequence) {
        // Output an earlier server kept per channel. Its operation is concluded at boot with an outcome its caller sees (the
        // server's rollout boundary), so the output is dropped and the next write deletes these rows. A row that does not open
        // is that record's damage, not output to skip.
        let _: ChannelPayload = try unseal(output.payload, key: key, context: row.grp + output.id)
        record.discard = true
        continue
      }
      let chunk: OutputChunk = try unseal(output.payload, key: key, context: row.grp + output.id)
      guard output.id == row.id + "/" + String(chunk.sequence), output.sequence == Int(chunk.sequence), output.channel == chunk.channel else {
        throw OperationError(.storeUnavailable, message: "Encrypted operation output is unavailable", operation: record.id)
      }
      record.output.append(chunk)
    }
    return record
  }

  /// The id an earlier server gave a retained output row: one sequence per channel.
  static func legacyOutputID(_ operation: String, channel: String, sequence: Int) -> String {
    operation + "/" + channel + "/" + String(sequence)
  }

  /// Writes the operation row and the channel rows that changed. Retained output rows are the caller's, except an earlier
  /// server's, which a discarding record deletes.
  static func writeState(_ record: ClientRecord, row original: MachineV2OperationRow, key: SymmetricKey, stamp: String, in db: Database) throws {
    var row = original
    var metadata = record
    metadata.committed = [:]; metadata.accepted = [:]; metadata.pendingInputs = [:]; metadata.output = []
    row.record = try seal(metadata, key: key, context: row.grp + row.id)
    row.active = record.live
    let retained = record.output.reduce(0) { $0 + $1.payload.byteCount } + record.pendingInputs.values.reduce(0) { $0 + $1.payload.byteCount }
    row.reservedBytes = row.active ? record.reservation : retained
    for (name, pending) in record.pendingInputs {
      guard let channel = record.inputChannels.first(where: { $0.name == name }) else { throw OperationError(.unknownChannel, operation: record.id) }
      let limit = min(channel.windowBytes, 64 * 1024)
      guard pending.payload.byteCount <= limit else { throw OperationError.capacityExceeded("pendingInputBytes", used: pending.payload.byteCount, limit: limit, operation: record.id) }
    }
    for channel in record.outputChannels where record.retainedBytes(channel.name) > channel.windowBytes {
      throw OperationError.capacityExceeded("outputBytes", used: record.retainedBytes(channel.name), limit: channel.windowBytes, operation: record.id)
    }
    if !row.active, try MachineV2RetentionRow.where({ $0.id.eq(row.id) }).fetchOne(db) == nil {
      let retention = MachineV2RetentionRow(id: row.id, grp: row.grp, kind: "operation", expiredAt: stamp)
      try MachineV2RetentionRow.insert { retention }.execute(db)
    }
    try MachineV2OperationRow.upsert { row }.execute(db)
    if record.discard, record.output.isEmpty {
      try MachineV2OutputRow.where { $0.operationID.eq(row.id) }.delete().execute(db)
    }
    var prior = try Dictionary(uniqueKeysWithValues: MachineV2ChannelRow.where { $0.operationID.eq(row.id) }.fetchAll(db).map { ($0.name, $0) })
    for name in Set(record.committed.keys).union(record.accepted.keys).union(record.pendingInputs.keys) {
      let id = row.id + "/" + name
      let old = prior.removeValue(forKey: name)
      let pending: String? = try record.pendingInputs[name].map { write in
        if let sealed = old?.pending, let stored: WriteRequest = try? unseal(sealed, key: key, context: row.grp + id), stored == write { return sealed }
        return try seal(write, key: key, context: row.grp + id)
      }
      let channel = MachineV2ChannelRow(id: id, operationID: row.id, name: name, committed: String(record.committed[name]?.rawValue ?? 0), accepted: String(record.accepted[name]?.rawValue ?? 0), pending: pending)
      if let old, old.committed == channel.committed, old.accepted == channel.accepted, old.pending == channel.pending { continue }
      try MachineV2ChannelRow.upsert { channel }.execute(db)
    }
    for stale in prior.values { try MachineV2ChannelRow.where { $0.id.eq(stale.id) }.delete().execute(db) }
  }
}
