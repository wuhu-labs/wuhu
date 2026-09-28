import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID

let sessionSchemaSQL = """
CREATE TABLE IF NOT EXISTS "sessions" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "allocation" INTEGER NOT NULL UNIQUE,
  "kind" TEXT NOT NULL,
  "parent" TEXT,
  "title" TEXT NOT NULL,
  "tags" TEXT NOT NULL,
  "created_by" TEXT NOT NULL,
  "executor" TEXT NOT NULL,
  "executor_config" TEXT NOT NULL,
  "created_at" TEXT NOT NULL,
  "last_activity_at" TEXT NOT NULL,
  "hold" TEXT NOT NULL,
  "work" TEXT NOT NULL,
  "lifecycle" TEXT NOT NULL,
  "grace_expires_at" TEXT,
  "error_message" TEXT,
  "run_state" TEXT NOT NULL,
  "run_heartbeat_at" TEXT,
  "run_progress_at" TEXT,
  "grp" TEXT NOT NULL DEFAULT ''
);
CREATE TRIGGER IF NOT EXISTS "sessions_grp_required" BEFORE INSERT ON "sessions" WHEN NEW."grp" = ''
  BEGIN SELECT RAISE(ABORT, 'grp required: sessions'); END;
CREATE INDEX IF NOT EXISTS "sessions_by_grp" ON "sessions" ("grp", "last_activity_at");
CREATE TABLE IF NOT EXISTS "session_runtime" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "generation" INTEGER NOT NULL,
  "queue_tail" INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS "session_generations" (
  "session_id" TEXT NOT NULL,
  "generation" INTEGER NOT NULL,
  "kept_count" INTEGER NOT NULL,
  PRIMARY KEY ("session_id", "generation")
);
CREATE TABLE IF NOT EXISTS "session_contents" (
  "session_id" TEXT NOT NULL,
  "id" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "id")
);
CREATE TABLE IF NOT EXISTS "session_pointers" (
  "session_id" TEXT NOT NULL,
  "generation" INTEGER NOT NULL,
  "position" INTEGER NOT NULL,
  "content_id" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "generation", "position")
);
CREATE TABLE IF NOT EXISTS "session_queue" (
  "session_id" TEXT NOT NULL,
  "id" INTEGER NOT NULL,
  "input_id" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  "enqueued_at" TEXT NOT NULL,
  "drained_at" TEXT,
  PRIMARY KEY ("session_id", "id")
);
CREATE UNIQUE INDEX IF NOT EXISTS "session_queue_dedup" ON "session_queue" ("session_id", "input_id");
CREATE TABLE IF NOT EXISTS "session_receipts" (
  "session_id" TEXT NOT NULL,
  "tool_call_id" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  "recorded_at" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "tool_call_id")
);
CREATE TABLE IF NOT EXISTS "session_subscriptions" (
  "session_id" TEXT NOT NULL,
  "subscription_id" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  "next_fire_at" TEXT,
  "marker" TEXT,
  "last_fired_at" TEXT,
  "armed_at" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "subscription_id")
);
"""

enum Sessions {
  // Foundation emits keyed containers in an order of its own choosing, and not
  // the same one twice, so stored payloads are sorted into canonical bytes.
  static func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  static func decode<T: Decodable>(_ type: T.Type, from payload: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(payload.utf8))
  }

  static func exists(_ key: String, in db: Database) throws -> Bool {
    try String.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?", arguments: [key]) != nil
  }

  // Nearest first. A parent is fixed at creation and must already exist, so
  // the walk ends; the bound only catches a hand-edited database.
  static func ancestors(_ key: String, in db: Database) throws -> [String] {
    var chain: [String] = []
    var cursor = try String.fetchOne(db, sql: "SELECT parent FROM sessions WHERE id = ?", arguments: [key])
    while let parent = cursor {
      precondition(chain.count < 4096, "session tree cycle above \(key)")
      chain.append(parent)
      cursor = try String.fetchOne(db, sql: "SELECT parent FROM sessions WHERE id = ?", arguments: [parent])
    }
    return chain
  }

  static func runtime(_ key: String, in db: Database) throws -> (generation: Int64, queueTail: Int64) {
    guard let row = try Row.fetchOne(
      db,
      sql: "SELECT generation, queue_tail FROM session_runtime WHERE session_id = ?",
      arguments: [key],
    ) else { throw SessionStoreError.unknownSession(key) }
    return (row["generation"], row["queue_tail"])
  }

  static func group(of key: String, in db: Database) throws -> GroupID {
    GroupID(rawValue: try String.fetchOne(db, sql: "SELECT grp FROM sessions WHERE id = ?", arguments: [key]) ?? GroupID.shared.rawValue)
  }

  static func record(_ key: String, in db: Database) throws -> SessionRecord {
    guard let row = try Row.fetchOne(
      db,
      sql: """
      SELECT id, kind, parent, title, tags, created_by, executor, executor_config,
             created_at, last_activity_at,
             hold, work, lifecycle, grace_expires_at, error_message, grp
      FROM sessions WHERE id = ?
      """,
      arguments: [key],
    ) else { throw SessionStoreError.unknownSession(key) }
    let lifecycle: SessionLifecycle = if row["lifecycle"] as String == "live" {
      .live
    } else {
      .archived(graceExpiresAt: try SQLiteDateFormat.date(from: row["grace_expires_at"]))
    }
    return SessionRecord(
      id: SessionID(row["id"] as String),
      kind: SessionKind(rawValue: row["kind"])!,
      parent: (row["parent"] as String?).map { SessionID($0) },
      title: row["title"],
      tags: try decode([String].self, from: row["tags"]),
      createdBy: row["created_by"],
      executor: try SessionExecutor(kind: row["executor"], configJSON: row["executor_config"]),
      createdAt: try SQLiteDateFormat.date(from: row["created_at"]),
      lastActivityAt: try SQLiteDateFormat.date(from: row["last_activity_at"]),
      hold: SessionHold(rawValue: row["hold"])!,
      work: SessionWork(rawValue: row["work"])!,
      errorMessage: row["error_message"],
      lifecycle: lifecycle,
      group: GroupID(rawValue: row["grp"]),
    )
  }

  static func transcript(_ key: String, in db: Database) throws -> Transcript {
    let runtime = try runtime(key, in: db)
    guard let keptCount = try Int.fetchOne(
      db,
      sql: "SELECT kept_count FROM session_generations WHERE session_id = ? AND generation = ?",
      arguments: [key, runtime.generation],
    ) else { throw SessionStoreError.unknownSession(key) }
    let payloads = try String.fetchAll(
      db,
      sql: """
      SELECT c.payload FROM session_pointers p
      JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
      WHERE p.session_id = ? AND p.generation = ?
      ORDER BY p.position
      """,
      arguments: [key, runtime.generation],
    )
    let items = try payloads.map { try decode(TranscriptItem.self, from: $0) }
    return Transcript(items: items, keptCount: keptCount)
  }

  // The next position comes from the pointer table, never from a caller's
  // count: an in-memory transcript that has drifted must not be able to
  // overwrite a row.
  static func nextPosition(_ key: String, generation: Int64, in db: Database) throws -> Int {
    try Int.fetchOne(
      db,
      sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM session_pointers WHERE session_id = ? AND generation = ?",
      arguments: [key, generation],
    ) ?? 0
  }

  static func append(
    _ key: String,
    generation: Int64,
    items: some Collection<TranscriptItem>,
    in db: Database,
  ) throws {
    let startPosition = try nextPosition(key, generation: generation, in: db)
    for (offset, item) in items.enumerated() {
      let contentID = item.id.uuidString.lowercased()
      try db.execute(
        sql: "INSERT INTO session_contents (session_id, id, payload) VALUES (?, ?, ?)",
        arguments: [key, contentID, try encode(item)],
      )
      try db.execute(
        sql: "INSERT INTO session_pointers (session_id, generation, position, content_id) VALUES (?, ?, ?, ?)",
        arguments: [key, generation, startPosition + offset, contentID],
      )
    }
  }

  static func openGeneration(_ key: String, generation: Int64, keptCount: Int, in db: Database) throws {
    try db.execute(
      sql: "INSERT INTO session_generations (session_id, generation, kept_count) VALUES (?, ?, ?)",
      arguments: [key, generation, keptCount],
    )
    try db.execute(
      sql: "UPDATE session_runtime SET generation = ? WHERE session_id = ?",
      arguments: [generation, key],
    )
  }

  static func undrained(_ key: String, tail: Int64, in db: Database) throws -> [SessionQueueEntry] {
    try Row.fetchAll(
      db,
      sql: "SELECT id, payload FROM session_queue WHERE session_id = ? AND id > ? ORDER BY id",
      arguments: [key, tail],
    ).map { row in
      SessionQueueEntry(id: Int(row["id"] as Int64), input: try decode(QueueInput.self, from: row["payload"]))
    }
  }

  static func markDrained(_ key: String, through id: Int64, now: String, in db: Database) throws {
    try db.execute(
      sql: "UPDATE session_queue SET drained_at = ? WHERE session_id = ? AND id <= ? AND drained_at IS NULL",
      arguments: [now, key, id],
    )
  }

  static func queueHead(_ key: String, tail: Int64, in db: Database) throws -> Int64 {
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ?",
      arguments: [key],
    ) ?? 0
    return max(maxID, tail)
  }

  static func receipt(_ key: String, toolCallID: String, in db: Database) throws -> ToolResultPayload? {
    guard let payload = try String.fetchOne(
      db,
      sql: "SELECT payload FROM session_receipts WHERE session_id = ? AND tool_call_id = ?",
      arguments: [key, toolCallID],
    ) else { return nil }
    return try decode(ToolResultPayload.self, from: payload)
  }

  static func recordReceipt(_ key: String, toolCallID: String, payload: String, now: String, in db: Database) throws {
    // The first recorded outcome is authoritative; a crash-retry that
    // re-records must not overwrite it.
    try db.execute(
      sql: """
      INSERT OR IGNORE INTO session_receipts (session_id, tool_call_id, payload, recorded_at)
      VALUES (?, ?, ?, ?)
      """,
      arguments: [key, toolCallID, payload, now],
    )
  }

  static func enqueue(_ key: String, input: QueueInput, nowDate: Date, in db: Database) throws -> Int {
    let record = try record(key, in: db)
    let inputID = input.id.uuidString.lowercased()
    if let existing = try Int64.fetchOne(
      db,
      sql: "SELECT id FROM session_queue WHERE session_id = ? AND input_id = ?",
      arguments: [key, inputID],
    ) {
      return Int(existing)
    }
    if case let .archived(graceExpiresAt) = record.lifecycle, nowDate >= graceExpiresAt {
      throw SessionStoreError.archiveGraceExpired(key)
    }
    let now = SQLiteDateFormat.string(from: nowDate)
    let next = (try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ?",
      arguments: [key],
    ) ?? 0) + 1
    try db.execute(
      sql: "INSERT INTO session_queue (session_id, id, input_id, payload, enqueued_at) VALUES (?, ?, ?, ?, ?)",
      arguments: [key, next, inputID, try encode(input.capped()), now],
    )
    if record.work == .noWork {
      try db.execute(
        sql: "UPDATE sessions SET work = 'has_work', last_activity_at = ? WHERE id = ?",
        arguments: [now, key],
      )
    }
    return Int(next)
  }

  static func markHasWork(_ key: String, now: String, in db: Database) throws {
    try db.execute(
      sql: "UPDATE sessions SET work = 'has_work', last_activity_at = ? WHERE id = ? AND work = 'no_work'",
      arguments: [now, key],
    )
  }

  // The coarse-transition gate: the induced sessions row is written only when
  // the derived work value actually flips, never per item.
  static func refreshWork(_ key: String, transcript: Transcript, now: String, in db: Database) throws {
    let current = try String.fetchOne(db, sql: "SELECT work FROM sessions WHERE id = ?", arguments: [key])!
    guard current != SessionWork.errored.rawValue else { return }
    let runtime = try runtime(key, in: db)
    let backlog = try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM session_queue WHERE session_id = ? AND id > ?",
      arguments: [key, runtime.queueTail],
    )!
    let derived = (backlog > 0 || transcript.hasWork) ? SessionWork.hasWork : SessionWork.noWork
    guard derived.rawValue != current else { return }
    try db.execute(
      sql: "UPDATE sessions SET work = ?, last_activity_at = ? WHERE id = ?",
      arguments: [derived.rawValue, now, key],
    )
  }
}
