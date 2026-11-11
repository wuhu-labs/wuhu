import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

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

  static func runtime(_ key: String, in db: Database) throws -> (generation: Int64, queueTail: Int64, stepTry: Int64) {
    guard let row = try Row.fetchOne(
      db,
      sql: "SELECT generation, queue_tail, step_try FROM session_runtime WHERE session_id = ?",
      arguments: [key],
    ) else { throw SessionStoreError.unknownSession(key) }
    return (row["generation"], row["queue_tail"], row["step_try"])
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
    guard let hold = SessionHold(rawValue: row["hold"]), hold != .unknown,
          let work = SessionWork(rawValue: row["work"]), work != .unknown
    else { preconditionFailure("Unknown stored session state") }
    let lifecycle: SessionLifecycle = if row["lifecycle"] as String == "live" {
      .live
    } else {
      .archived(graceExpiresAt: try SQLiteDateFormat.date(from: row["grace_expires_at"]))
    }
    var executor = try SessionExecutor(kind: row["executor"], configJSON: row["executor_config"])
    if case .kernel = executor,
       let route = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db),
       let group = route.groupID
    {
      let pin = try decode(SessionModelRoute.self, from: route.payload)
      executor = .modelGroup(id: group, effort: pin.specifier.effort)
    }
    return SessionRecord(
      id: SessionID(row["id"] as String),
      kind: SessionKind(rawValue: row["kind"])!,
      parent: (row["parent"] as String?).map { SessionID($0) },
      title: row["title"],
      tags: try decode([String].self, from: row["tags"]),
      createdBy: row["created_by"],
      executor: executor,
      createdAt: try SQLiteDateFormat.date(from: row["created_at"]),
      lastActivityAt: try SQLiteDateFormat.date(from: row["last_activity_at"]),
      hold: hold,
      work: work,
      errorMessage: row["error_message"],
      lifecycle: lifecycle,
      group: GroupID(rawValue: row["grp"]),
    )
  }

  static func transcript(_ key: String, in db: Database) throws -> Transcript {
    try transcript(key, generation: try runtime(key, in: db).generation, count: nil, in: db)
  }

  static func transcript(_ key: String, generation: Int64, count: Int?, in db: Database) throws -> Transcript {
    guard let keptCount = try Int.fetchOne(
      db,
      sql: "SELECT kept_count FROM session_generations WHERE session_id = ? AND generation = ?",
      arguments: [key, generation],
    ) else { throw SessionStoreError.unknownSession(key) }
    let payloads = try String.fetchAll(
      db,
      sql: """
      SELECT c.payload FROM session_pointers p
      JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
      WHERE p.session_id = ? AND p.generation = ?
      ORDER BY p.position
      LIMIT ?
      """,
      arguments: [key, generation, count ?? -1],
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
    try writeLines(key, generation: generation, appending: items, after: startPosition, in: db)
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

  /// An input is due once its `due_at` is not after the time bound to `?`; one without is due at once. Each decision binds one time to every query it makes, so they agree on what is due.
  static let due = "(due_at IS NULL OR due_at <= ?)"

  /// The due inputs past `tail`, in order.
  static func undrained(_ key: String, tail: Int64, at clock: String, in db: Database) throws -> [SessionQueueEntry] {
    try Row.fetchAll(
      db,
      sql: "SELECT id, payload FROM session_queue WHERE session_id = ? AND id > ? AND \(due) ORDER BY id",
      arguments: [key, tail, clock],
    ).map { row in
      SessionQueueEntry(id: Int(row["id"] as Int64), input: try decode(QueueInput.self, from: row["payload"]))
    }
  }

  static func firings(of inputs: [QueueInput], in db: Database) throws -> [String] {
    var messages: [String] = []
    var requests: [String] = []
    for input in inputs {
      switch input {
      case let .message(message):
        messages.append(message.messageID.rawValue)
        if let request = message.requestID { requests.append(request.rawValue) }
      case let .notification(notification):
        if let request = notification.requestID { requests.append(request.rawValue) }
      }
    }
    guard !messages.isEmpty || !requests.isEmpty else { return [] }
    return try String.fetchAll(
      db,
      sql: """
      SELECT firing FROM messages WHERE firing IS NOT NULL AND id IN (\(databaseQuestionMarks(count: messages.count)))
      UNION SELECT firing FROM requests WHERE firing IS NOT NULL AND id IN (\(databaseQuestionMarks(count: requests.count)))
      ORDER BY firing
      """,
      arguments: StatementArguments(messages + requests),
    )
  }

  static func markDrained(_ key: String, through id: Int64, now: String, in db: Database) throws {
    try db.execute(
      sql: "UPDATE session_queue SET drained_at = ? WHERE session_id = ? AND id <= ? AND drained_at IS NULL",
      arguments: [now, key, id],
    )
  }

  /// The last due input, or `tail` when none waits.
  static func queueHead(_ key: String, tail: Int64, at clock: String, in db: Database) throws -> Int64 {
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ? AND \(due)",
      arguments: [key, clock],
    ) ?? 0
    return max(maxID, tail)
  }

  /// Moves the inputs past `tail` that are not due yet behind every other, so the due ones drain as one run from `tail`.
  static func deferNotDue(_ key: String, tail: Int64, at clock: String, in db: Database) throws {
    let later = try Int64.fetchAll(
      db,
      sql: "SELECT id FROM session_queue WHERE session_id = ? AND id > ? AND NOT \(due) ORDER BY id",
      arguments: [key, tail, clock],
    )
    guard !later.isEmpty else { return }
    var next = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ?", arguments: [key])!
    for id in later {
      next += 1
      try db.execute(sql: "UPDATE session_queue SET id = ? WHERE session_id = ? AND id = ?", arguments: [next, key, id])
    }
  }

  /// When a new input on `topic` is due: the one it replaces keeps its time,
  /// else no sooner than `throttle` past the last one the model saw.
  private static func throttledDue(_ key: String, topic: String, throttle: Double, now: Date, in db: Database) throws -> Date {
    let tail = try runtime(key, in: db).queueTail
    let last = try Row.fetchOne(
      db,
      sql: "SELECT id, enqueued_at, COALESCE(due_at, enqueued_at) AS due FROM session_queue WHERE session_id = ? AND topic = ? ORDER BY id DESC LIMIT 1",
      arguments: [key, topic],
    )
    guard let last else { return now }
    let due = try SQLiteDateFormat.date(from: last["due"])
    guard (last["id"] as Int64) <= tail else { return due }
    let seen = max(due, try SQLiteDateFormat.date(from: last["enqueued_at"]))
    return max(now, seen.addingTimeInterval(throttle))
  }

  static func removeInput(_ key: String, topic: String, in db: Database) throws {
    let tail = try runtime(key, in: db).queueTail
    try db.execute(sql: "DELETE FROM session_queue WHERE session_id = ? AND topic = ? AND id > ?", arguments: [key, topic, tail])
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

  static func apiReceipt(_ key: String, toolCallID: String, in db: Database) throws -> APIReceipt? {
    guard let row = try Row.fetchOne(
      db,
      sql: "SELECT status, body, request FROM session_api_receipts WHERE session_id = ? AND tool_call_id = ?",
      arguments: [key, toolCallID],
    ) else { return nil }
    return APIReceipt(status: row["status"], body: row["body"], request: row["request"])
  }

  static func recordAPIReceipt(_ key: String, toolCallID: String, _ receipt: APIReceipt, now: String, in db: Database) throws {
    try db.execute(
      sql: """
      INSERT OR IGNORE INTO session_api_receipts (session_id, tool_call_id, status, body, recorded_at, request)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      arguments: [key, toolCallID, receipt.status, receipt.body, now, receipt.request],
    )
  }

  /// The session cell's write of an input it was sent; one it already has is not queued twice.
  static func insertInput(_ key: String, _ put: SessionPut, nowDate: Date, in db: Database) throws {
    let record = try record(key, in: db)
    let inputID = put.input.id.uuidString.lowercased()
    guard try Int64.fetchOne(db, sql: "SELECT id FROM session_queue WHERE session_id = ? AND input_id = ?", arguments: [key, inputID]) == nil else { return }
    let now = SQLiteDateFormat.string(from: nowDate)
    var due = put.due
    if let topic = put.topic {
      if let throttle = put.throttle { due = try throttledDue(key, topic: topic, throttle: throttle, now: nowDate, in: db) }
      try removeInput(key, topic: topic, in: db)
    }
    let next = (try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ?",
      arguments: [key],
    ) ?? 0) + 1
    let later = due.flatMap { $0 > nowDate ? SQLiteDateFormat.string(from: $0) : nil }
    try db.execute(
      sql: "INSERT INTO session_queue (session_id, id, input_id, payload, enqueued_at, topic, due_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [key, next, inputID, try encode(put.input.capped()), now, put.topic, later],
    )
    if record.work == .noWork, later == nil {
      try db.execute(
        sql: "UPDATE sessions SET work = 'has_work', last_activity_at = ? WHERE id = ?",
        arguments: [now, key],
      )
    }
  }

  static func markHasWork(_ key: String, now: String, in db: Database) throws {
    try db.execute(
      sql: "UPDATE sessions SET work = 'has_work', last_activity_at = ? WHERE id = ? AND work = 'no_work'",
      arguments: [now, key],
    )
  }

  // The coarse-transition gate: the induced sessions row is written only when
  // a derived axis actually flips, never per item. Besides `work`, the row
  // carries what the loop is doing (`run_state`): `tool` while a tool call is
  // unanswered, `inference` while the model owes the next step, `no_run`
  // otherwise. `run_progress_at` is when that phase began, and
  // `last_activity_at` moves with every flip, so a session waiting in a long
  // tool call reads as such instead of as one that never ran.
  static func refreshWork(_ key: String, transcript: Transcript, now: String, in db: Database) throws {
    let row = try Row.fetchOne(db, sql: "SELECT work, hold, lifecycle FROM sessions WHERE id = ?", arguments: [key])!
    let current: String = row["work"]
    let hold: String = row["hold"]
    let lifecycle: String = row["lifecycle"]
    guard current != SessionWork.errored.rawValue else { return }
    let runtime = try runtime(key, in: db)
    let backlog = try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM session_queue WHERE session_id = ? AND id > ? AND \(due)",
      arguments: [key, runtime.queueTail, now],
    )!
    let derived = (backlog > 0 || transcript.hasWork) ? SessionWork.hasWork : SessionWork.noWork
    let running = hold == SessionHold.normal.rawValue && lifecycle == "live"
    let run: SessionRunState = if !running {
      .noRun
    } else if !transcript.pendingToolCallIDs.isEmpty {
      .tool
    } else if derived == .hasWork {
      .inference
    } else {
      .noRun
    }
    if derived.rawValue != current {
      try db.execute(
        sql: "UPDATE sessions SET work = ?, last_activity_at = ? WHERE id = ?",
        arguments: [derived.rawValue, now, key],
      )
    }
    try setRunState(key, run, now: now, in: db)
  }

  /// Drained input is unanswered by construction, so a running session's
  /// next step is the model's.
  static func markInferenceOwed(_ key: String, now: String, in db: Database) throws {
    let row = try Row.fetchOne(db, sql: "SELECT work, hold, lifecycle FROM sessions WHERE id = ?", arguments: [key])!
    let work: String = row["work"]
    let hold: String = row["hold"]
    let lifecycle: String = row["lifecycle"]
    guard work == SessionWork.hasWork.rawValue, hold == SessionHold.normal.rawValue, lifecycle == "live" else { return }
    try setRunState(key, .inference, now: now, in: db)
  }

  /// Writes `run_state` only when it changes; a flip stamps
  /// `run_progress_at` and `last_activity_at`.
  static func setRunState(_ key: String, _ run: SessionRunState, now: String, in db: Database) throws {
    try db.execute(
      sql: """
      UPDATE sessions SET run_state = ?, run_progress_at = ?, last_activity_at = ?
      WHERE id = ? AND run_state <> ?
      """,
      arguments: [run.rawValue, run == .noRun ? nil : now, now, key, run.rawValue],
    )
  }
}

/// What a kernel session's loop is doing, as the `run_state` column of the
/// induced `sessions` table shows it.
enum SessionRunState: String, Sendable {
  case inference
  case tool
  case noRun = "no_run"
}
