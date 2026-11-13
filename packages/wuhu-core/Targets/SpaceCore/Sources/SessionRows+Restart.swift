import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

public struct SessionRestart: Hashable, Sendable, Codable {
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

extension SessionRows {
  /// Start over: a new generation whose head lists `armed` (without it, what the stores hold once the queue is recovered: a session whose cell has no list yet), the session's hold and error cleared, and its queue kept.
  @discardableResult
  public func restart(
    _ id: SessionID,
    executor: SessionExecutor?,
    note: String?,
    modelRoute: SessionModelRoute?,
    runningWork: [String],
    armed: [SubscriptionID: Subscription]? = nil,
    uuid: () -> UUID,
  ) throws -> SessionRestart {
    let key = id.rawValue
    let nowDate = store.dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    var head = GenerationHead(
      id: uuid(), timestamp: nowDate, summary: "", snapshot: StateSnapshot(), note: note, runningWork: runningWork,
    )
    let record = try Sessions.record(key, in: db)
    try (executor ?? record.executor).requireSupported()
    guard record.lifecycle == .live else { throw SessionStoreError.restartOfArchivedSession(key) }
    let storedExecutor = try Sessions.concreteExecutor(executor ?? record.executor, route: modelRoute)
    if executor != nil || modelRoute != nil {
      try db.execute(
        sql: "UPDATE sessions SET executor = ?, executor_config = ? WHERE id = ?",
        arguments: [storedExecutor.kind, storedExecutor.configJSON, key],
      )
    }
    try Sessions.writeModelRoute(key, route: modelRoute, in: db)
    let runtime = try Sessions.runtime(key, in: db)
    let queue = try Sessions.recoverRestartQueue(key, tail: runtime.queueTail, in: db)
    if queue.dropped > 0 {
      let dropped = "Dropped \(queue.dropped) queued input(s) that could not be read."
      head.note = [note, dropped].compactMap(\.self).joined(separator: "\n")
    }
    let generation = runtime.generation + 1
    head.snapshot = .init(subscriptions: try armed ?? armedSlots(id).slots)
    try Sessions.openGeneration(key, generation: generation, in: db)
    try Sessions.appendLines(key, generation: generation, head.lines(session: id), in: db)
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
    try SessionPrompts.invalidate(key, in: db)
    if try Sessions.queueHead(key, tail: queue.tail, at: now, in: db) > queue.tail { try Sessions.markHasWork(key, now: now, in: db) }
    return SessionRestart(generation: Int(generation), executor: try Sessions.record(key, in: db).executor)
  }
}

extension SessionRows {
  /// What the stores hold of the session's own slots, and which of them run a handler: its rows of `subscription_slots` but the children watch, the plain timers waiting on its queue and its streams. Only for a session whose cell has not listed them yet.
  public func armedSlots(_ id: SessionID) throws -> (slots: [SubscriptionID: Subscription], handlers: Set<SubscriptionID>) {
    var slots: [SubscriptionID: Subscription] = [:]
    var handlers: Set<SubscriptionID> = []
    for row in try SubscriptionRow.of(.session(id)).fetchAll(db) {
      let slot = try store.armedSubscription(row).slot
      guard let subscription = slot.kind.subscription else { continue }
      slots[slot.id] = subscription
      if slot.handler != nil { handlers.insert(slot.id) }
    }
    for notice in try Sessions.pendingTimers(id.rawValue, in: db) {
      slots[notice.subscriptionID] = notice.schedule.map(Subscription.timer)
    }
    for stream in try Sessions.streams(id.rawValue, in: db) {
      slots[stream.id] = .stream(stream.url)
    }
    return (slots, handlers)
  }
}

extension SessionStore {
  /// The executor a restart onto `executor` stores: a model group is stored as the model it was placed on.
  public static func restartExecutor(_ executor: SessionExecutor, route: SessionModelRoute?) throws -> SessionExecutor {
    try Sessions.concreteExecutor(executor, route: route)
  }

  public func generation(_ id: SessionID) async throws -> Int {
    let key = id.rawValue
    return try await writer.read { db in Int(try Sessions.runtime(key, in: db).generation) }
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
    if try record(key, in: db).executor.isRetired { return GenerationState(generation: Int(generation), note: nil) }
    return GenerationState(generation: Int(generation), note: try lineText(key, generation: generation, lineKey: "head:note", in: db)?.text)
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
        readable.append(row["id"])
      } catch where isUnreadableSessionData(error) {
        dropped += 1
      }
    }
    guard dropped > 0 else { return (tail, 0) }
    let head = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM session_queue WHERE session_id = ?", arguments: [key])!
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
