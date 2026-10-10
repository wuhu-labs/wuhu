import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

public struct SessionRestart: Hashable, Sendable {
  public var generation: Int
  public var executor: SessionExecutor

  public init(generation: Int, executor: SessionExecutor) {
    self.generation = generation
    self.executor = executor
  }
}

public struct GenerationState: Hashable, Sendable {
  public var generation: Int
  public var note: String?

  public init(generation: Int, note: String?) {
    self.generation = generation
    self.note = note
  }
}

extension SessionStore {
  @discardableResult
  public func restart(
    _ id: SessionID,
    executor: SessionExecutor? = nil,
    note: String? = nil,
  ) async throws -> SessionRestart {
    @Dependency(\.uuid) var uuid
    let key = id.rawValue
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    let head = GenerationHead(
      id: uuid(), timestamp: nowDate, summary: "", snapshot: StateSnapshot(), note: note,
    )
    let (restart, hasQueuedInput) = try await writer.write { db in
      let record = try Sessions.record(key, in: db)
      try (executor ?? record.executor).requireSupported()
      guard record.lifecycle == .live else { throw SessionStoreError.restartOfArchivedSession(key) }
      let stopped = record.hold == .interrupted || record.work == .errored
      guard stopped || record.work != .hasWork else { throw SessionStoreError.busyForRestart(key) }
      if let executor {
        try db.execute(
          sql: "UPDATE sessions SET executor = ?, executor_config = ? WHERE id = ?",
          arguments: [executor.kind, executor.configJSON, key],
        )
      }
      let runtime = try Sessions.runtime(key, in: db)
      try db.execute(sql: "DELETE FROM session_commands WHERE session_id = ?", arguments: [key])
      var subscriptions: [SubscriptionID: Subscription] = [:]
      for armed in try Row.fetchAll(
        db, sql: "SELECT * FROM session_subscriptions WHERE session_id = ?", arguments: [key],
      ).map(self.armedSubscription) {
        switch armed.slot.kind {
        case let .observe(sql, _): subscriptions[armed.slot.id] = .observe(sql: sql)
        case let .timer(schedule, _): subscriptions[armed.slot.id] = .timer(schedule)
        case .requestDeadline:
          guard let deadline = armed.nextFireAt else { throw SessionStoreError.requestDeadlineWithoutFireDate(armed.slot.id.rawValue) }
          subscriptions[armed.slot.id] = .requestDeadline(deadline)
        case .parkReminder:
          try db.execute(
            sql: "DELETE FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
            arguments: [key, armed.slot.id.rawValue],
          )
        }
      }
      var head = head
      do {
        var settle: SettleState
        do {
          settle = try Sessions.settleState(key, through: nowDate, in: db)
        } catch where isUnreadableSessionData(error) {
          settle = SettleState()
        }
        settle.openRequests = settle.openRequests.mapValues { request in
          var request = request
          request.parkReminderCount = 0
          request.lastParkReminderAt = nil
          return request
        }
        head.settle = settle
      }
      let queue = try Sessions.recoverRestartQueue(key, tail: runtime.queueTail, in: db)
      if queue.dropped > 0 {
        let dropped = "Dropped \(queue.dropped) queued input(s) that could not be read."
        head.note = [note, dropped].compactMap(\.self).joined(separator: "\n")
      }
      let generation = runtime.generation + 1
      do {
        head.snapshot = .init(subscriptions: subscriptions)
        head.settleBoundary = .init(
          queueTail: queue.tail,
          messageTail: try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(n), 0) FROM messages WHERE sender_session_id = ?", arguments: [key])!,
        )
        try Sessions.writeGeneration(key, generation: generation, transcript: Transcript().compacted(head: head, kept: nil), in: db)
      }
      try db.execute(
        sql: """
        UPDATE sessions
        SET hold = 'normal', work = 'no_work', error_message = NULL,
            run_state = 'no_run', run_heartbeat_at = NULL, run_progress_at = NULL,
            last_activity_at = ?
        WHERE id = ?
        """,
        arguments: [now, key],
      )
      try PromptRevisions.advance(key, in: db)
      let queueHead = try Sessions.queueHead(key, tail: queue.tail, in: db)
      let hasQueuedInput = queueHead > queue.tail
      if hasQueuedInput { try Sessions.markHasWork(key, now: now, in: db) }
      return (SessionRestart(
        generation: Int(generation),
        executor: try Sessions.record(key, in: db).executor,
      ), hasQueuedInput)
    }
    if hasQueuedInput { signals.post(id) }
    return restart
  }

  public func generationState(_ id: SessionID) async throws -> GenerationState {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.generationState(key, in: db)
    }
  }
}

extension Sessions {
  static func generationState(_ key: String, in db: Database) throws -> GenerationState {
    let generation = try runtime(key, in: db).generation
    switch try record(key, in: db).executor {
    case .kernel, .contractor: break
    case .claudeCode: return GenerationState(generation: Int(generation), note: nil)
    }
    let payload = try String.fetchOne(
      db,
      sql: """
      SELECT c.payload FROM session_pointers p
      JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
      WHERE p.session_id = ? AND p.generation = ? AND p.position = 0
      """,
      arguments: [key, generation],
    )
    guard let payload, case let .generationHead(head) = try decode(TranscriptItem.self, from: payload) else {
      return GenerationState(generation: Int(generation), note: nil)
    }
    return GenerationState(generation: Int(generation), note: head.note)
  }
}

extension Sessions {
  static func recoverRestartQueue(_ key: String, tail: Int64, in db: Database) throws -> (tail: Int64, dropped: Int) {
    let rows = try Row.fetchAll(
      db, sql: "SELECT * FROM session_queue WHERE session_id = ? AND id > ? ORDER BY id", arguments: [key, tail],
    )
    var readable: [Int64] = []
    var dropped = 0
    for row in rows {
      do {
        _ = try decode(QueueInput.self, from: row["payload"])
        _ = try SQLiteDateFormat.date(from: row["enqueued_at"])
        if let drainedAt = row["drained_at"] as String? { _ = try SQLiteDateFormat.date(from: drainedAt) }
        readable.append(row["id"])
      } catch where isUnreadableSessionData(error) {
        dropped += 1
      }
    }
    guard dropped > 0 else { return (tail, 0) }
    let head = try queueHead(key, tail: tail, in: db)
    for (offset, id) in readable.enumerated() {
      try db.execute(
        sql: "UPDATE session_queue SET id = ? WHERE session_id = ? AND id = ?",
        arguments: [head + Int64(offset) + 1, key, id],
      )
    }
    try db.execute(sql: "UPDATE session_runtime SET queue_tail = ? WHERE session_id = ?", arguments: [head, key])
    return (head, dropped)
  }
}
