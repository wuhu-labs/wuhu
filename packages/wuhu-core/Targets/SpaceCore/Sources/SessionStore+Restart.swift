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
    let claudeSessionID = uuid().uuidString.lowercased()
    return try await writer.write { db in
      let record = try Sessions.record(key, in: db)
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
      // Retiring the queue by advancing the tail, not by deleting rows: ids are
      // minted from MAX(id), and a daemon's in-memory cursor outlives the
      // restart, so a shrinking id space would strand the next delivery.
      let queueHead = try Sessions.queueHead(key, tail: runtime.queueTail, in: db)
      try db.execute(
        sql: "UPDATE session_runtime SET queue_tail = ? WHERE session_id = ?",
        arguments: [queueHead, key],
      )
      try Sessions.markDrained(key, through: queueHead, now: now, in: db)
      try db.execute(sql: "DELETE FROM session_commands WHERE session_id = ?", arguments: [key])
      try db.execute(sql: "DELETE FROM session_subscriptions WHERE session_id = ?", arguments: [key])
      let generation = runtime.generation + 1
      switch executor ?? record.executor {
      case .kernel, .contractor:
        var head = head
        do {
          head.settle = try Sessions.settleState(key, through: nowDate, in: db)
        } catch where isUnreadableSessionData(error) {
          head.settle = SettleState()
        }
        head.settleBoundary = .init(
          queueTail: queueHead,
          messageTail: try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(n), 0) FROM messages WHERE sender_session_id = ?", arguments: [key])!,
        )
        try Sessions.openGeneration(key, generation: generation, keptCount: 1, in: db)
        try Sessions.append(key, generation: generation, items: [TranscriptItem.generationHead(head)], in: db)
      case .claudeCode:
        // Claude Code's log has no head row: the note waits beside the fresh
        // conversation id and goes in with the first delivery.
        try Sessions.openGeneration(key, generation: generation, keptCount: 0, in: db)
        try Sessions.beginClaudeCodeGeneration(key, claudeSessionID: claudeSessionID, note: note, in: db)
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
      // Deliberately no work signal: a restarted session is as inert as a
      // created one, and waking it would spend a turn on its own note.
      return SessionRestart(
        generation: Int(generation),
        executor: try Sessions.record(key, in: db).executor,
      )
    }
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
