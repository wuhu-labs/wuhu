#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SessionDomain.SessionID
import StructuredQueries

let sessionWorkerOwnershipSchemaSQL = """
CREATE TABLE IF NOT EXISTS "execution_worker_owners" (
  "incarnation" TEXT NOT NULL PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS "session_worker_assignments" (
  "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "incarnation" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "incarnation")
);
CREATE TABLE IF NOT EXISTS "worker_script_owners" (
  "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "script_id" TEXT NOT NULL,
  "incarnation" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "script_id", "incarnation")
);
"""

@Table("execution_worker_owners")
struct ExecutionWorkerOwnerRow {
  @Column(primaryKey: true) var incarnation: String
}

@Table("session_worker_assignments")
struct SessionWorkerAssignmentRow {
  @Column("session_id") var sessionID: String
  var incarnation: String
}

@Table("worker_script_owners")
struct WorkerScriptOwnerRow {
  @Column("session_id") var sessionID: String
  @Column("script_id") var scriptID: String
  var incarnation: String
}

extension SessionStore {
  /// Establishes complete ownership tracking before the child can start.
  public func beginWorkerOwnership(incarnation: UUID) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      try ExecutionWorkerOwnerRow.insert { ExecutionWorkerOwnerRow(incarnation: incarnation) }.execute(db)
    }
  }

  public func assignWorker(_ id: SessionID, incarnation: UUID) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      let rows = SessionWorkerAssignmentRow.where { $0.sessionID.eq(id.rawValue) && $0.incarnation.eq(incarnation) }
      if try rows.fetchOne(db) == nil {
        try SessionWorkerAssignmentRow.insert { SessionWorkerAssignmentRow(sessionID: id.rawValue, incarnation: incarnation) }.execute(db)
      }
    }
  }

  public func releaseWorkerAssignment(_ id: SessionID, incarnation: UUID) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      try SessionWorkerAssignmentRow.where { $0.sessionID.eq(id.rawValue) && $0.incarnation.eq(incarnation) }.delete().execute(db)
    }
  }

  public func registerWorkerScript(_ script: String, session: SessionID, incarnation: UUID) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      try WorkerScriptOwnerRow.insert { WorkerScriptOwnerRow(sessionID: session.rawValue, scriptID: script, incarnation: incarnation) }.execute(db)
    }
  }

  public func releaseWorkerScript(_ script: String, session: SessionID, incarnation: UUID) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      try WorkerScriptOwnerRow.where { $0.sessionID.eq(session.rawValue) && $0.scriptID.eq(script) && $0.incarnation.eq(incarnation) }.delete().execute(db)
    }
  }

  /// Nil means at least one incarnation predates complete ownership tracking.
  public func sessionsOwnedByWorkers(_ incarnations: Set<UUID>) async throws -> Set<SessionID>? {
    let incarnations = Set(incarnations.map(\.uuidString))
    return try await writer.read { db in
      let tracked = try Set(ExecutionWorkerOwnerRow.fetchAll(db).map(\.incarnation))
      guard incarnations.isSubset(of: tracked) else { return nil }
      let assignments = try SessionWorkerAssignmentRow.fetchAll(db).filter { incarnations.contains($0.incarnation) }.map(\.sessionID)
      let scripts = try WorkerScriptOwnerRow.fetchAll(db).filter { incarnations.contains($0.incarnation) }.map(\.sessionID)
      return Set((assignments + scripts).map(SessionID.init(rawValue:)))
    }
  }
}
