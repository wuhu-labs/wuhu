#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SessionDomain.SessionID
import StructuredQueries

let sessionWorkerSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_worker_incarnations" (
  "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "incarnation" TEXT NOT NULL,
  "died_at" REAL,
  PRIMARY KEY ("session_id", "incarnation")
);
"""

@Table("session_worker_incarnations")
struct SessionWorkerIncarnationRow {
  @Column("session_id") var sessionID: String
  var incarnation: String
  @Column("died_at") var diedAt: Double?
}

extension SessionStore {
  public func setWorkerActivity(_ id: SessionID, incarnation: UUID, active: Bool) async throws {
    let incarnation = incarnation.uuidString
    try await writer.write { db in
      let matching = SessionWorkerIncarnationRow.where { $0.sessionID.eq(id.rawValue) && $0.incarnation.eq(incarnation) }
      if active {
        if try matching.fetchOne(db) == nil {
          try SessionWorkerIncarnationRow.insert { SessionWorkerIncarnationRow(sessionID: id.rawValue, incarnation: incarnation) }.execute(db)
        }
      } else {
        try matching.where { $0.diedAt.is(nil) }.delete().execute(db)
      }
    }
  }

  /// Nil finalizes active leases left by a previous parent; a specific incarnation finalizes only that child's leases.
  public func recordWorkerLoss(incarnation: UUID? = nil, excluding: Set<UUID> = []) async throws -> [SessionID: Bool] {
    let incarnation = incarnation?.uuidString
    let excluding = Set(excluding.map(\.uuidString))
    let now = dateGen.now.timeIntervalSince1970
    return try await writer.write { db in
      try SessionWorkerIncarnationRow.where { $0.diedAt.lt(#bind(Optional(now - 600))) }.delete().execute(db)
      let active = try SessionWorkerIncarnationRow.where { $0.diedAt.is(nil) }.fetchAll(db)
        .filter { !excluding.contains($0.incarnation) && (incarnation == nil || $0.incarnation == incarnation) }
      for row in active {
        try SessionWorkerIncarnationRow.where { $0.sessionID.eq(row.sessionID) && $0.incarnation.eq(row.incarnation) }
          .update { $0.diedAt = #bind(now) }.execute(db)
      }
      let deaths = try SessionWorkerIncarnationRow.where { $0.diedAt.isNot(nil) }.fetchAll(db)
      return Dictionary(uniqueKeysWithValues: Set(active.map(\.sessionID)).map { key in
        (SessionID(key), deaths.filter { $0.sessionID == key }.count >= 3)
      })
    }
  }

  public func workerCrashFenced(_ id: SessionID) async throws -> Bool {
    let cutoff = dateGen.now.timeIntervalSince1970 - 600
    return try await writer.write { db in
      try SessionWorkerIncarnationRow.where { $0.diedAt.lt(#bind(Optional(cutoff))) }.delete().execute(db)
      return try SessionWorkerIncarnationRow.where { $0.sessionID.eq(id.rawValue) && $0.diedAt.isNot(nil) }.fetchAll(db).count >= 3
    }
  }
}
