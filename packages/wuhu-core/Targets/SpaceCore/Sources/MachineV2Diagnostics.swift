#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import enum JSONValue.JSONValue
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationTrace
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

public enum MachineV2Presence: String, Sendable { case attached, detached, lost }

public struct MachineV2PresenceEvidence: Sendable {
  public let state: MachineV2Presence
  public let observedAt: Date
  public let reason: String?
}

extension Space {
  public func registerMachineV2(_ machine: String, group: GroupID) async throws {
    guard let record = try await resolveMachine(machine, usableFrom: group), record.id.rawValue == machine, record.group == group else { throw OperationError(.unknownMachine) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      let row = MachineV2MemberRow(machineID: machine, grp: group.rawValue, createdAt: stamp)
      try MachineV2MemberRow.upsert { row }.execute(db)
    }
  }

  public func machineV2Members(group: GroupID) async throws -> [String] {
    try await writer.read { db in try MachineV2MemberRow.where { $0.grp.eq(group.rawValue) }.fetchAll(db).map(\.machineID) }
  }

  public func machineV2DetachedMembers(group: GroupID) async throws -> Set<String> {
    try await writer.read { db in
      Set(try MachineV2PresenceRow.where { $0.grp.eq(group.rawValue) && $0.state.eq("detached") }.fetchAll(db).map(\.machineID))
    }
  }

  public func machineV2PresenceEvidence(_ machine: String, group: GroupID) async throws -> MachineV2PresenceEvidence? {
    try await writer.read { db in
      let state: MachineV2Presence
      let stamp: String
      let reason: String?
      if let row = try MachineV2PresenceRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) {
        guard let stored = MachineV2Presence(rawValue: row.state) else { throw OperationError(.storeUnavailable, message: "Machine v2 presence evidence is invalid") }
        state = stored; stamp = row.observedAt; reason = row.reason
      } else if let member = try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) {
        state = .lost; stamp = member.createdAt; reason = "neverAttached"
      } else { return nil }
      let observedAt: Date
      do { observedAt = try SQLiteDateFormat.date(from: stamp) }
      catch { throw OperationError(.storeUnavailable, message: "Machine v2 presence evidence is invalid") }
      return .init(state: state, observedAt: observedAt, reason: reason)
    }
  }

  /// A connection alone is not evidence; the coordinator supplies this only after describe, settled leave, or local lease expiry.
  public func recordMachineV2Presence(_ machine: String, group: GroupID, state: MachineV2Presence, description: MachineDescription? = nil, reason: String? = nil) async throws {
    guard state != .attached || description != nil else { throw OperationError(.invalidInput) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    let json = try description.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    try await writer.write { db in
      guard let member = try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) else { throw OperationError(.unknownMachine) }
      let prior = try MachineV2PresenceRow.where { $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }.fetchOne(db)
      let observedAt: String
      if state == .lost { observedAt = prior?.observedAt ?? member.createdAt }
      else { observedAt = stamp }
      let row = MachineV2PresenceRow(machineID: machine, grp: group.rawValue, state: state.rawValue, description: json, observedAt: observedAt, reason: reason)
      try MachineV2PresenceRow.upsert { row }.execute(db)
    }
  }

  public func machineV2TraceSink(group: GroupID, problemsGroup: GroupID?) throws -> @Sendable (OperationTrace) throws -> Void {
    guard let problemsGroup else { throw OperationError(.traceUnavailable, message: "Machine v2 needs an explicit problems group") }
    if machineTraces == nil {
      machineTraces = MachineTraceWriter(writer: writer, date: dateGen, clock: clock, broadcast: broadcast, log: log)
    }
    let buffer = machineTraces!
    return { trace in
      guard trace.path.hasPrefix("/machine/v2/machines/"), !trace.path.contains("?"), !trace.path.contains("#"),
            trace.path.utf8.count <= 4096, trace.correlation.utf8.count <= 256,
            trace.elapsed >= .zero, trace.elapsed.components.seconds < Int64(Int.max / 1000)
      else { throw OperationError(.traceUnavailable) }
      buffer.append(trace, group: group, problemsGroup: problemsGroup)
    }
  }

  public func pinMachineV2Trace(group: GroupID, correlation: String, problem: Int64?) async throws {
    let problemsGroup = machineTraces?.problemsGroup(for: group) ?? group
    try await writer.write { db in
      let rows = try MachineV2TraceRow.where { $0.grp.eq(group.rawValue) && $0.correlationID.eq(correlation) }.fetchAll(db)
      for var row in rows { row.problemID = problem; try MachineV2TraceRow.upsert { row }.execute(db) }
      let incidents = try MachineV2IncidentRow.where { $0.traceGroup.eq(group.rawValue) && $0.correlationID.eq(correlation) }.fetchAll(db)
      for var row in incidents { row.problemID = problem; try MachineV2IncidentRow.upsert { row }.execute(db) }
      if incidents.isEmpty {
        let marker = MachineV2IncidentRow(id: "pin/" + group.rawValue + "/" + correlation, grp: problemsGroup.rawValue, traceGroup: group.rawValue, fingerprint: "explicitPin", correlationID: correlation, problemID: problem)
        try MachineV2IncidentRow.upsert { marker }.execute(db)
      }
    }
  }

  public func recordMachineV2Problem(group: GroupID, traceGroup: GroupID, invariant: Int, code: OperationError.Code, incident: String, correlation: UUID?) async throws -> Int64 {
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    return try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      try V2Problems.record(group: group, traceGroup: traceGroup, invariant: invariant, code: code, incident: incident, correlation: correlation, stamp: stamp, in: db, pending: &pending)
    }
  }
}

enum V2Problems {
  static let path = try! SpacePath(validating: "/wuhu/machine-v2-problems.table")
  static let header: TableHeader = {
    let names = ["first_seen_at", "last_seen_at", "occurrences", "fingerprint", "invariant", "error_code", "status"]
    return TableHeader(columns: names.map { .init(name: $0, type: ["occurrences", "invariant"].contains($0) ? .integer : .text) })
  }()

  static func releaseResolvedPins(group: GroupID, stamp: String, cutoff: String, in db: Database) throws {
    let pinned = try MachineV2IncidentRow.where { $0.grp.eq(group.rawValue) && $0.problemID.isNot(nil) }.fetchAll(db)
    for id in Set(pinned.compactMap(\.problemID)) {
      let fields = try Tables.openPayload(path, group: group, id: id, in: db)
      guard case let .string(status)? = fields["status"], ["fixed", "verified", "accepted"].contains(status) else { continue }
      for var incident in pinned where incident.problemID == id {
        incident.problemID = nil; try MachineV2IncidentRow.upsert { incident }.execute(db)
        let retention = MachineV2RetentionRow(id: incident.id, grp: group.rawValue, kind: "incident", expiredAt: stamp)
        try MachineV2RetentionRow.upsert { retention }.execute(db)
      }
      for incident in pinned where incident.problemID == id {
        guard let correlation = incident.correlationID else { continue }
        try MachineV2TraceRow.where { $0.grp.eq(incident.traceGroup) && $0.correlationID.eq(correlation) && $0.problemID.eq(id) }
          .update { $0.problemID = #bind(nil as Int64?) }.execute(db)
      }
    }
    let expired = try MachineV2RetentionRow.where { $0.grp.eq(group.rawValue) && $0.kind.eq("incident") && $0.expiredAt.lt(cutoff) }.fetchAll(db)
    for entry in expired {
      try MachineV2IncidentRow.where { $0.id.eq(entry.id) && $0.problemID.is(nil) }.delete().execute(db)
      try MachineV2RetentionRow.where { $0.id.eq(entry.id) }.delete().execute(db)
    }
  }

  static func record(group: GroupID, traceGroup: GroupID, invariant: Int, code: OperationError.Code, incident: String, correlation: UUID?, stamp: String, in db: Database, pending: inout [MutationEvent]) throws -> Int64 {
    guard (1 ... 28).contains(invariant), !incident.isEmpty else { throw OperationError(.invalidInput) }
    let fingerprint = "\(invariant)/protocol/\(code.rawValue)"
    let indexID = group.rawValue + "/" + fingerprint
    let incidentID = group.rawValue + "/" + traceGroup.rawValue + "/" + incident + "/" + fingerprint
    let prior = try MachineV2ProblemIndex.where { $0.id.eq(indexID) }.fetchOne(db)
    if try MachineV2IncidentRow.where({ $0.id.eq(incidentID) }).fetchOne(db) != nil, let prior { return prior.rowID }
    let revision = try Substrate.mintRevision(mtime: stamp, group: group, in: db)
    if try Substrate.head(path, group: group, in: db) == nil { try Tables.create(path, group: group, header: header, rev: revision, mtime: stamp, in: db) }
    let current = try Tables.currentHeader(path, group: group, in: db)
    guard current == header else { throw OperationError(.storeUnavailable, message: "Machine v2 problems schema differs") }
    var fields: [String: JSONValue]
    if let prior { fields = try Tables.openPayload(path, group: group, id: prior.rowID, in: db) }
    else {
      fields = Dictionary(uniqueKeysWithValues: header.columns.map { ($0.name, .null) })
      fields["first_seen_at"] = .string(stamp)
      fields["occurrences"] = 0; fields["fingerprint"] = .string(fingerprint); fields["invariant"] = .integer(invariant)
      fields["error_code"] = .string(code.rawValue); fields["status"] = "open"
    }
    if case let .integer(count)? = fields["occurrences"] { fields["occurrences"] = .integer(count + 1) }
    fields["last_seen_at"] = .string(stamp)
    let cells = header.columns.map { fields[$0.name] ?? .null }
    let id: Int64
    if let prior { id = prior.rowID; try Tables.updateRow(path, group: group, header: header, id: id, cells: cells, rev: revision, in: db) }
    else {
      id = try Tables.insertRow(path, group: group, header: header, cells: cells, rev: revision, in: db)
      let index = MachineV2ProblemIndex(id: indexID, grp: group.rawValue, fingerprint: fingerprint, rowID: id)
      try MachineV2ProblemIndex.insert { index }.execute(db)
    }
    let event = MachineV2IncidentRow(id: incidentID, grp: group.rawValue, traceGroup: traceGroup.rawValue, fingerprint: fingerprint, correlationID: correlation?.uuidString, problemID: id)
    try MachineV2IncidentRow.insert { event }.execute(db)
    if let correlation {
      let traces = try MachineV2TraceRow.where { $0.grp.eq(traceGroup.rawValue) && $0.correlationID.eq(correlation.uuidString) }.fetchAll(db)
      for var trace in traces { trace.problemID = id; try MachineV2TraceRow.upsert { trace }.execute(db) }
    }
    try Substrate.touchTableNode(path, group: group, rev: revision, mtime: stamp, in: db)
    pending.append(MutationEvent(group: group, path: path.rawValue, rev: Int(revision), kind: .write, entry: .table))
    return id
  }
}

enum V2Maintenance {
  static func due(_ id: String, now: Date, in db: Database) throws -> Bool {
    let threshold = SQLiteDateFormat.string(from: now.addingTimeInterval(-300))
    if let prior = try MachineV2MaintenanceRow.where({ $0.id.eq(id) }).fetchOne(db), prior.ranAt > threshold { return false }
    let row = MachineV2MaintenanceRow(id: id, ranAt: SQLiteDateFormat.string(from: now))
    try MachineV2MaintenanceRow.upsert { row }.execute(db)
    return true
  }
}
