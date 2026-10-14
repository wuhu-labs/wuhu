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

  /// A connection alone is not evidence; the coordinator supplies this only after describe, settled leave, or local lease expiry.
  public func recordMachineV2Presence(_ machine: String, group: GroupID, state: MachineV2Presence, description: MachineDescription? = nil, reason: String? = nil) async throws {
    guard state != .attached || description != nil else { throw OperationError(.invalidInput) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    let json = try description.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    try await writer.write { db in
      guard try MachineV2MemberRow.where({ $0.machineID.eq(machine) && $0.grp.eq(group.rawValue) }).fetchOne(db) != nil else { throw OperationError(.unknownMachine) }
      let row = MachineV2PresenceRow(machineID: machine, grp: group.rawValue, state: state.rawValue, description: json, observedAt: stamp, reason: reason)
      try MachineV2PresenceRow.upsert { row }.execute(db)
    }
  }

  public func machineV2TraceSink(group: GroupID, problemsGroup: GroupID?) throws -> @Sendable (OperationTrace) throws -> Void {
    guard let problemsGroup else { throw OperationError(.traceUnavailable, message: "Machine v2 needs an explicit problems group") }
    let writer = writer; let date = dateGen; let broadcast = broadcast
    return { trace in
      guard trace.path.hasPrefix("/machine/v2/machines/"), !trace.path.contains("?"), !trace.path.contains("#") else { throw OperationError(.traceUnavailable) }
      let now = date.now; let stamp = SQLiteDateFormat.string(from: now)
      let cutoff = SQLiteDateFormat.string(from: now.addingTimeInterval(-7 * 86400))
      let parts = trace.elapsed.components
      guard parts.seconds >= 0, parts.seconds < Int64(Int.max / 1000) else { throw OperationError(.traceUnavailable) }
      let elapsed = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
      try writer.writeWithoutTransaction { db in
        var pending: [MutationEvent] = []
        try db.inTransaction {
          let id = group.rawValue + "/" + trace.request.uuidString
          let prior = try MachineV2TraceRow.where { $0.id.eq(id) }.fetchOne(db)
          var row = MachineV2TraceRow(id: id, grp: group.rawValue, requestID: trace.request.uuidString, correlationID: trace.correlation, path: trace.path, event: trace.event.rawValue, startAt: prior?.startAt ?? stamp, elapsedMs: elapsed, status: trace.status ?? prior?.status, headMs: trace.event == .head ? elapsed : prior?.headMs, errorCode: trace.error?.rawValue, problemID: prior?.problemID)
          if let incident = try MachineV2IncidentRow.where({ $0.traceGroup.eq(group.rawValue) && $0.correlationID.eq(trace.correlation) }).fetchOne(db) { row.problemID = incident.problemID }
          try MachineV2TraceRow.upsert { row }.execute(db)
          if let code = trace.error, [.invalidResponse, .invalidOffset, .offsetExpired].contains(code) {
            let parts = trace.path.split(separator: "/").map(String.init)
            let operation = parts.count >= 6 ? UUID(uuidString: parts[5]) : nil
            _ = try V2Problems.record(group: problemsGroup, traceGroup: group, invariant: 13, code: code, incident: operation?.uuidString ?? trace.request.uuidString, correlation: UUID(uuidString: trace.correlation), stamp: stamp, in: db, pending: &pending)
          }
          if try V2Maintenance.due("problems/" + problemsGroup.rawValue, now: now, in: db) { try V2Problems.releaseResolvedPins(group: problemsGroup, stamp: stamp, cutoff: cutoff, in: db) }
          if try V2Maintenance.due("traces/" + group.rawValue, now: now, in: db) { try MachineV2TraceRow.where { $0.grp.eq(group.rawValue) && $0.startAt.lt(cutoff) && $0.problemID.is(nil) }.delete().execute(db) }
          return .commit
        }
        if !pending.isEmpty { broadcast.emit(Dictionary(grouping: pending, by: \.group).map { group, events in FSCommit(group: group, rev: events[0].rev, events: events) }) }
      }
    }
  }

  public func pinMachineV2Trace(group: GroupID, correlation: String, problem: Int64?) async throws {
    try await writer.write { db in
      let rows = try MachineV2TraceRow.where { $0.grp.eq(group.rawValue) && $0.correlationID.eq(correlation) }.fetchAll(db)
      for var row in rows { row.problemID = problem; try MachineV2TraceRow.upsert { row }.execute(db) }
      let incidents = try MachineV2IncidentRow.where { $0.traceGroup.eq(group.rawValue) && $0.correlationID.eq(correlation) }.fetchAll(db)
      for var row in incidents { row.problemID = problem; try MachineV2IncidentRow.upsert { row }.execute(db) }
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
      let traceGroups = Set(pinned.filter { $0.problemID == id }.map(\.traceGroup))
      let traces = try MachineV2TraceRow.where { $0.problemID.eq(id) }.fetchAll(db).filter { traceGroups.contains($0.grp) }
      for var trace in traces { trace.problemID = nil; try MachineV2TraceRow.upsert { trace }.execute(db) }
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
