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
    try Sessions.append(key, generation: runtime.generation, items: items, in: db)
    try db.execute(
      sql: "UPDATE session_runtime SET queue_tail = ? WHERE session_id = ?",
      arguments: [lastID, key],
    )
    try Sessions.markDrained(key, through: Int64(lastID), now: now, in: db)
    try Sessions.putNextTimers(key, after: entries.map(\.input), now: try SQLiteDateFormat.date(from: now), in: db)
    return QueueDrain(items: items, queueTail: lastID, firings: try Sessions.firings(of: entries.map(\.input), in: db))
  }

  /// `items` go after the generation's tail; `inputOrigin` is the appended
  /// transcript's `cacheWarmingInputOrigin`, the one thing of it the store
  /// keeps.
  public func append(_ id: SessionID, items: [TranscriptItem], inputOrigin: Bool?) throws {
    guard !items.isEmpty else { return }
    let key = id.rawValue
    let runtime = try Sessions.runtime(key, in: db)
    try Sessions.append(key, generation: runtime.generation, items: items, in: db)
    if items.contains(where: { if case .assistant = $0 { true } else { false } }) {
      try CacheWarmingRow.recordInference(key, origin: inputOrigin, now: store.dateGen.now, in: db)
    }
  }

  public func writeCompaction(
    _ id: SessionID,
    closing: ToolResultItem? = nil,
    head: GenerationHead,
    kept: Range<Int>?,
    transition: ModelRouteTransition? = nil,
  ) throws -> Transcript {
    let key = id.rawValue
    let runtime = try Sessions.runtime(key, in: db)
    let transcript = try Sessions.transcript(key, in: db)
    // The closing result joins the OLD generation in the same commit; the
    // kept range never includes it (it was computed before the close).
    if let closing {
      try Sessions.append(key, generation: runtime.generation, items: [TranscriptItem.toolResult(closing)], in: db)
    }
    let compacted = transition?.transcript ?? transcript.compacted(head: head, kept: kept)
    if let transition {
      try Sessions.commitRouteTransition(key, transition: transition, in: db)
      let existing = Set(transcript.items.map(\.id))
      for item in compacted.items.dropFirst() where !existing.contains(item.id) {
        let row = SessionContentRow(sessionID: key, id: item.id.uuidString.lowercased(), payload: try Sessions.encode(item))
        try SessionContentRow.insert { row }.execute(db)
      }
    }
    try Sessions.writeGeneration(key, generation: runtime.generation + 1, transcript: compacted, in: db)
    try SessionPrompts.advance(key, in: db)
    return compacted
  }

  public func writePortableHandoff(_ id: SessionID, transcript: Transcript) throws -> Transcript {
    precondition(transcript.pendingToolCallIDs.isEmpty)
    guard case let .generationHead(head)? = transcript.items.first, head.replayBinding != nil else {
      preconditionFailure("portable handoff requires a bound generation head")
    }
    let key = id.rawValue
    let runtime = try Sessions.runtime(key, in: db)
    let old = try Sessions.transcript(key, in: db)
    let existing = Dictionary(uniqueKeysWithValues: old.items.map { ($0.id, $0) })
    guard old.pendingToolCallIDs.isEmpty else { throw PortableHandoffError.outstandingToolCalls }
    for item in transcript.items.dropFirst() {
      if let original = existing[item.id] {
        precondition(original == item, "rewritten handoff items require new content IDs")
      } else {
        let row = SessionContentRow(sessionID: key, id: item.id.uuidString.lowercased(), payload: try Sessions.encode(item))
        try SessionContentRow.insert { row }.execute(db)
      }
    }
    try Sessions.writeGeneration(key, generation: runtime.generation + 1, transcript: transcript, in: db)
    try SessionPrompts.advance(key, in: db)
    return transcript
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

  /// A forced compaction is an inference the turn does not owe: it can start from a settled turn, and shows as `inference` until the turn next moves.
  public func markCompacting(_ id: SessionID) throws {
    let key = id.rawValue
    let record = try Sessions.record(key, in: db)
    guard record.work != .errored, record.hold == .normal, case .live = record.lifecycle else { return }
    try Sessions.setRunState(key, .inference, now: now, in: db)
  }

  public func markErrored(_ id: SessionID, message: String) throws {
    let key = id.rawValue
    let now = now
    let record: SessionRecord?
    do {
      record = try Sessions.record(key, in: db)
    } catch where isUnreadableSessionData(error) {
      record = nil
    }
    try db.execute(
      sql: """
      UPDATE sessions SET work = 'errored', error_message = ?, last_activity_at = ?,
          run_state = 'no_run', run_progress_at = NULL
      WHERE id = ?
      """,
      arguments: [message, now, key],
    )
    let transcript: Transcript
    do {
      transcript = switch record?.executor {
      case .kernel, .modelGroup: try Sessions.transcript(key, in: db)
      case .retired, nil: Transcript()
      }
    } catch where isUnreadableSessionData(error) {
      transcript = Transcript()
    }
    try Notifications.fireErrored(key, error: message, transcript: transcript, now: now, in: db)
    let runtime = store.runtime
    db.afterNextTransaction { _ in runtime.poke(person: Notifications.ownerRecipient) }
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
    if let parent = try Sessions.record(id.rawValue, in: db).parent { try SessionStore.unwatchChildren(parent, in: db) }
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
      try SessionStore.watchChildren(parent, now: SQLiteDateFormat.string(from: nowDate), in: db)
    }
  }
}

extension SessionStore {
  func rows<T: Sendable>(_ body: @escaping @Sendable (SessionRows) throws -> T) async throws -> T {
    try await writer.write { db in try body(SessionRows(db: db, store: self)) }
  }
}
