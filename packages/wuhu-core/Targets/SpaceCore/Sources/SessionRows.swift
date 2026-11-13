import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

/// The writes a session makes to its own tables, in a transaction its caller holds: the session cell's, on wuwei's shared backend, takes them through the space writer's own connection.
public struct SessionRows {
  let db: Database
  let store: SessionStore

  /// `host` is the space writer's connection, as wuwei's shared backend lends it to a cell.
  public init(host: AnyObject?, store: SessionStore) {
    guard let db = host as? Database else { preconditionFailure("session rows need the space writer's connection") }
    self.init(db: db, store: store)
  }

  init(db: Database, store: SessionStore) {
    self.db = db
    self.store = store
  }

  var now: String { SQLiteDateFormat.string(from: store.dateGen.now) }

  public func hydrate(_ id: SessionID) throws -> SessionHydration {
    try Sessions.hydrate(id.rawValue, at: now, in: db)
  }

  public func openRequests(_ id: SessionID) throws -> [OpenRequest] {
    try RequestRow.open(task: id.rawValue, in: db).map {
      OpenRequest(id: RequestID($0.id))
    }
  }

  /// When the work at hand should give the turn back: nil while no due input waits.
  public func yieldDeadline(_ id: SessionID) throws -> Date? {
    try Sessions.yieldDeadline(id.rawValue, at: now, in: db)
  }

  /// When the next input that is not due yet comes due.
  public func nextDue(_ id: SessionID) throws -> Date? {
    try String.fetchOne(
      db,
      sql: """
      SELECT MIN(q.due_at) FROM session_queue AS q JOIN session_runtime AS r ON r.session_id = q.session_id
      WHERE q.session_id = ? AND q.id > r.queue_tail AND q.due_at > ?
      """,
      arguments: [id.rawValue, now],
    ).map(SQLiteDateFormat.date(from:))
  }

  /// What the session's turn owes, shown on its row with whether due input waits: the cell says so whenever its turn moves.
  public func show(_ id: SessionID, owed: SessionRunState) throws {
    try Sessions.refreshWork(id.rawValue, owed: owed, now: now, in: db)
  }

  public func drainQueue(_ id: SessionID) throws -> QueueDrain {
    let key = id.rawValue
    let now = now
    let runtime = try Sessions.runtime(key, in: db)
    let clock = now
    try Sessions.deferNotDue(key, tail: runtime.queueTail, at: clock, in: db)
    let entries = try Sessions.undrained(key, tail: runtime.queueTail, at: clock, in: db)
    guard let lastID = entries.last?.id else {
      return QueueDrain(items: [], queueTail: Int(runtime.queueTail))
    }
    let generationStart = try Sessions.generationStart(key, generation: runtime.generation, in: db)
    var quoted: Set<ConversationID> = []
    let items = try entries.map { entry -> TranscriptItem in
      guard case var .message(message) = entry.input else { return entry.input.transcriptItem }
      message.sender = try Sessions.attributed(message.sender, in: db)
      if let generationStart, quoted.insert(message.conversationID).inserted {
        let exchange = try Conversations.staleExchange(
          message.conversationID, session: key, generation: runtime.generation, startedAt: generationStart, in: db,
        )
        message.content = message.content.following(try exchange.map { earlier in
          EarlierMessage(id: earlier.id, sender: try Sessions.attributed(earlier.sender, in: db), timestamp: earlier.createdAt, text: earlier.content.text)
        })
      }
      return .message(message)
    }
    try Sessions.appendLines(key, generation: runtime.generation, items.flatMap { $0.lines(session: id) }, in: db)
    try db.execute(
      sql: "UPDATE session_runtime SET queue_tail = ? WHERE session_id = ?",
      arguments: [lastID, key],
    )
    try Sessions.markDrained(key, through: Int64(lastID), now: now, in: db)
    try Sessions.putNextTimers(key, after: entries.map(\.input), now: try SQLiteDateFormat.date(from: now), in: db)
    return QueueDrain(items: items, queueTail: lastID, firings: try Sessions.firings(of: entries.map(\.input), in: db))
  }

  /// `lines` go after the generation's last; the first position taken is returned.
  @discardableResult
  public func append(_ id: SessionID, lines: [TranscriptLine]) throws -> Int {
    let key = id.rawValue
    return Int(try Sessions.appendLines(key, generation: try Sessions.runtime(key, in: db).generation, lines, in: db))
  }

  /// Whether a new generation would leave something behind: the generation holds more than its head and the pressure notices it was given.
  public func droppable(_ id: SessionID) throws -> Bool {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return try #sql("""
    SELECT EXISTS (SELECT 1 FROM session_lines
      WHERE session_id = \(bind: key) AND generation = \(bind: generation)
        AND key NOT IN ('system', 'group', 'session')
        AND key NOT GLOB \(bind: LineKey.head + "*") AND key != \(bind: LineKey.pressure))
    """, as: Bool.self).fetchOne(db)!
  }

  public func transcriptLineCount(_ id: SessionID) throws -> Int {
    let key = id.rawValue
    return try Sessions.transcriptLineCount(key, generation: Sessions.runtime(key, in: db).generation, in: db)
  }

  public func lastReplyPosition(_ id: SessionID) throws -> Int? {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.role.eq(TranscriptLine.Role.assistant.rawValue) }
      .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db).map(Int.init)
  }

  public func lastLineRole(_ id: SessionID) throws -> TranscriptLine.Role? {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    return try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order { $0.position.desc() }.limit(1).select(\.role).fetchOne(db).flatMap(TranscriptLine.Role.init(rawValue:))
  }

  /// The generation's lines after its prompt's, in position order.
  public func transcriptLines(_ id: SessionID) throws -> [StoredTranscriptLine] {
    let key = id.rawValue
    return try Sessions.transcriptLines(key, generation: try Sessions.runtime(key, in: db).generation, in: db)
  }

  /// Closes the generation with `closing` and opens the next: its head, the lines at the positions `kept` as a new generation carries them (`TranscriptLine.carried`, without the pressure notices), then `after`. A transition that changes the account commits with it and makes the carried lines portable. Returns the new generation.
  @discardableResult
  public func writeGeneration(
    _ id: SessionID,
    closing: [TranscriptLine] = [],
    head: GenerationHead,
    kept: Range<Int>? = nil,
    portable: Bool = false,
    after: [TranscriptLine] = [],
    transition: ModelRouteTransition? = nil,
  ) throws -> Int {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    try Sessions.appendLines(key, generation: generation, closing, in: db)
    var lines = head.lines(session: id)
    if let kept {
      let portable = portable || transition?.binding != nil
      lines += try Sessions.transcriptLines(key, generation: generation, in: db)
        .filter { kept.contains($0.position) && $0.key != LineKey.pressure }
        .compactMap { try $0.line().carried(portable: portable) }
    }
    if let transition { try Sessions.commitRouteTransition(key, transition: transition, in: db) }
    try Sessions.openGeneration(key, generation: generation + 1, in: db)
    try Sessions.appendLines(key, generation: generation + 1, lines + after, in: db)
    try SessionPrompts.invalidate(key, in: db)
    return Int(generation) + 1
  }

  public func markInterrupted(_ id: SessionID) throws {
    let key = id.rawValue
    let now = now
    _ = try Sessions.record(key, in: db)
    try db.execute(sql: "UPDATE sessions SET hold = 'interrupted', last_activity_at = ? WHERE id = ?", arguments: [now, key])
    try Sessions.setRunState(key, .noRun, now: now, in: db)
  }

  /// Also counts the resume, which asks the step it stopped at again.
  public func markResumed(_ id: SessionID) throws {
    let key = id.rawValue
    let now = now
    let record = try Sessions.record(key, in: db)
    try record.executor.requireSupported()
    try db.execute(
      sql: "UPDATE sessions SET hold = 'normal', error_message = NULL, last_activity_at = ? WHERE id = ?",
      arguments: [now, key],
    )
    try db.execute(sql: "UPDATE session_runtime SET step_try = step_try + 1 WHERE session_id = ?", arguments: [key])
    if record.work == .errored {
      try db.execute(sql: "UPDATE sessions SET work = 'no_work' WHERE id = ?", arguments: [key])
    }
  }

  /// `title` is already usable (``SessionStore/usableTitle(_:)``).
  public func retitle(_ id: SessionID, _ title: String) throws {
    let key = id.rawValue
    _ = try Sessions.record(key, in: db)
    try db.execute(sql: "UPDATE sessions SET title = ?, last_activity_at = ? WHERE id = ?", arguments: [title, now, key])
  }

  /// The whole list is replaced, whatever the session's lifecycle: an archived session can be retagged to tidy history.
  public func retag(_ id: SessionID, _ tags: [String]) throws {
    let key = id.rawValue
    _ = try Sessions.record(key, in: db)
    try db.execute(sql: "UPDATE sessions SET tags = ? WHERE id = ?", arguments: [try Sessions.encode(tags), key])
  }

  @discardableResult
  public func archive(_ id: SessionID, grace: Duration) throws -> Date {
    let nowDate = store.dateGen.now
    let deadline = nowDate.addingTimeInterval(grace.timeInterval)
    try db.execute(
      sql: """
      UPDATE sessions SET lifecycle = 'archived', grace_expires_at = ?, last_activity_at = ?,
          run_state = 'no_run', run_progress_at = NULL
      WHERE id = ?
      """,
      arguments: [SQLiteDateFormat.string(from: deadline), SQLiteDateFormat.string(from: nowDate), id.rawValue],
    )
    if let parent = try Sessions.record(id.rawValue, in: db).parent { try SessionStore.unwatchChildren(parent, runtime: store.runtime, in: db) }
    return deadline
  }

  public func unarchive(_ id: SessionID) throws {
    let key = id.rawValue
    let nowDate = store.dateGen.now
    let record = try Sessions.record(key, in: db)
    guard case let .archived(graceExpiresAt) = record.lifecycle else { return }
    try record.executor.requireSupported()
    guard nowDate < graceExpiresAt else { throw SessionStoreError.archiveGraceExpired(key) }
    try db.execute(
      sql: "UPDATE sessions SET lifecycle = 'live', grace_expires_at = NULL, last_activity_at = ? WHERE id = ?",
      arguments: [SQLiteDateFormat.string(from: nowDate), key],
    )
    if let parent = record.parent, try Sessions.record(parent.rawValue, in: db).lifecycle == .live {
      try SessionStore.watchChildren(parent, now: SQLiteDateFormat.string(from: nowDate), runtime: store.runtime, in: db)
    }
  }
}
