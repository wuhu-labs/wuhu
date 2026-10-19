#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct MachineContract.ExecID
import SessionDomain

// An exec whose tool call already returned `running`: its end is owed to the
// session as one message. The row outlives a server restart, which re-adopts
// the exec from `spec`, the owner's own encoding of how to rejoin it.
let execJobSchemaSQL = """
CREATE TABLE IF NOT EXISTS "exec_jobs" (
  "session_id" TEXT NOT NULL,
  "tool_call_id" TEXT NOT NULL,
  "exec_id" TEXT NOT NULL,
  "notice_id" TEXT NOT NULL,
  "spec" TEXT NOT NULL,
  "started_at" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "tool_call_id")
);
"""

public struct ExecJobRecord: Equatable, Sendable {
  public let session: SessionID
  public let toolCallID: ToolCallID
  public let exec: ExecID
  /// The id of the one message that delivers the job's end, so a delivery
  /// repeated after a crash lands once.
  public let notice: UUID
  public let spec: String
  public let startedAt: Date

  public init(session: SessionID, toolCallID: ToolCallID, exec: ExecID, notice: UUID, spec: String, startedAt: Date) {
    self.session = session; self.toolCallID = toolCallID; self.exec = exec; self.notice = notice; self.spec = spec; self.startedAt = startedAt
  }
}

extension SessionStore {
  /// Records the call's `running` receipt and the owed job in one write, so a
  /// crash leaves either a call to retry or a job to re-adopt, never both.
  public func detachExecJob(_ job: ExecJobRecord, payload: ToolResultPayload) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let encoded = try Sessions.encode(payload)
    try await writer.write { db in
      try Sessions.recordReceipt(job.session.rawValue, toolCallID: job.toolCallID.rawValue, payload: encoded, now: now, in: db)
      try db.execute(
        sql: """
        INSERT OR IGNORE INTO exec_jobs (session_id, tool_call_id, exec_id, notice_id, spec, started_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [
          job.session.rawValue, job.toolCallID.rawValue, job.exec.rawValue, job.notice.uuidString.lowercased(),
          job.spec, SQLiteDateFormat.string(from: job.startedAt),
        ],
      )
    }
  }

  public func execJobs() async throws -> [ExecJobRecord] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM exec_jobs ORDER BY started_at, exec_id").map { row in
        guard let notice = UUID(uuidString: row["notice_id"]) else {
          throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "exec_jobs row with an unreadable notice id")
        }
        return ExecJobRecord(
          session: SessionID(rawValue: row["session_id"]),
          toolCallID: ToolCallID(row["tool_call_id"] as String),
          exec: ExecID(rawValue: row["exec_id"]),
          notice: notice,
          spec: row["spec"],
          startedAt: try SQLiteDateFormat.date(from: row["started_at"]),
        )
      }
    }
  }

  /// Delivers the job's end, when there is one to say, and forgets the job in
  /// the same write. A session that can no longer take the message still
  /// loses the job.
  public func settleExecJob(_ session: SessionID, toolCallID: ToolCallID, notification: SystemNotification?, onCommit: @escaping @Sendable () -> Void = {}) async throws {
    let key = session.rawValue
    let nowDate = dateGen.now
    let forget: @Sendable (Database) throws -> Void = { db in
      try db.execute(
        sql: "DELETE FROM exec_jobs WHERE session_id = ? AND tool_call_id = ?",
        arguments: [key, toolCallID.rawValue],
      )
      db.afterNextTransaction { _ in onCommit() }
    }
    guard let notification else { return try await writer.write(forget) }
    do {
      try await writer.write { db in
        _ = try Sessions.enqueue(key, input: .notification(notification), nowDate: nowDate, in: db)
        try forget(db)
      }
      signals.post(session)
    } catch let error as SessionStoreError {
      try await writer.write(forget)
      throw error
    }
  }
}
