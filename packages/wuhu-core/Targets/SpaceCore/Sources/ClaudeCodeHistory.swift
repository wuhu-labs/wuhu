#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

let claudeCodeHistorySchemaSQL = """
CREATE INDEX IF NOT EXISTS "claude_code_handovers_by_session" ON "claude_code_handovers" ("session_id");
CREATE TABLE IF NOT EXISTS "claude_history_progress" (
  "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "version" INTEGER NOT NULL, "epoch" TEXT NOT NULL,
  "next_line" INTEGER NOT NULL, "offset" INTEGER NOT NULL, "count" INTEGER NOT NULL,
  "raw_head" INTEGER NOT NULL, "handover_head" INTEGER NOT NULL, "summary_position" INTEGER NOT NULL, "ready" INTEGER NOT NULL,
  PRIMARY KEY ("session_id", "generation")
);
CREATE TABLE IF NOT EXISTS "claude_history_items" (
  "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "position" INTEGER NOT NULL,
  "payload" TEXT NOT NULL, "origin" INTEGER, "call_id" TEXT,
  PRIMARY KEY ("session_id", "generation", "position")
);
CREATE TABLE IF NOT EXISTS "claude_history_seen" (
  "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "uuid" TEXT NOT NULL,
  PRIMARY KEY ("session_id", "generation", "uuid")
);
CREATE TABLE IF NOT EXISTS "claude_history_calls" (
  "session_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "call_id" TEXT NOT NULL,
  "origin" INTEGER NOT NULL, "wuhu" INTEGER NOT NULL,
  PRIMARY KEY ("session_id", "generation", "call_id")
);
"""

@Table("claude_history_progress")
struct ClaudeHistoryProgress {
  @Column("session_id") var sessionID: String
  var generation: Int64
  var version: Int
  var epoch: String
  @Column("next_line") var nextLine: Int64
  var offset: Int64
  var count: Int64
  @Column("raw_head") var rawHead: Int64
  @Column("handover_head") var handoverHead: Int64
  @Column("summary_position") var summaryPosition: Int64
  var ready: Bool

  static let currentVersion = 1

  func rawPosition() -> Int64 {
    guard summaryPosition >= 0 else { return nextLine }
    if nextLine == 0 { return summaryPosition }
    return nextLine <= summaryPosition ? nextLine - 1 : nextLine
  }
}

@Table("claude_history_items")
struct ClaudeHistoryItem {
  @Column("session_id") var sessionID: String
  var generation: Int64
  var position: Int64
  var payload: String
  var origin: Int64?
  @Column("call_id") var callID: String?
}

@Table("claude_history_seen")
struct ClaudeHistorySeen {
  @Column("session_id") var sessionID: String
  var generation: Int64
  var uuid: String
}

@Table("claude_history_calls")
struct ClaudeHistoryCall {
  @Column("session_id") var sessionID: String
  var generation: Int64
  @Column("call_id") var callID: String
  var origin: Int64
  var wuhu: Bool
}

extension Sessions {
  static func claudeHistoryProgress(_ key: String, generation: Int64, in db: Database) throws -> ClaudeHistoryProgress? {
    try ClaudeHistoryProgress.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.fetchOne(db)
  }

  static func claudeCodeHistoryEpoch(_ key: String, in db: Database) throws -> String? {
    let generation = try runtime(key, in: db).generation
    return try claudeHistoryProgress(key, generation: generation, in: db)?.epoch
  }

  static func claudeHistoryRawHead(_ key: String, generation: Int64, in db: Database) throws -> Int64 {
    try SessionPointerRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db) ?? -1
  }

  static func claudeHistoryHandoverHead(_ key: String, in db: Database) throws -> Int64 {
    try ClaudeHistoryEffect.where { $0.sessionID.eq(key) }.order { $0.rowID.desc() }.limit(1).select(\.rowID).fetchOne(db) ?? 0
  }

  static func readyClaudeHistory(_ key: String, generation: Int64, in db: Database) throws -> ClaudeHistoryProgress {
    guard let progress = try claudeHistoryProgress(key, generation: generation, in: db),
          progress.version == ClaudeHistoryProgress.currentVersion, progress.ready,
          progress.rawHead == (try claudeHistoryRawHead(key, generation: generation, in: db)),
          progress.handoverHead == (try claudeHistoryHandoverHead(key, in: db))
    else { throw TranscriptHistoryError.preparing(generation: Int(generation)) }
    return progress
  }

  static func claudeCodeHistory(
    _ key: String, generation: Int64, limit: Int, before: Int?, expectedEpoch: String? = nil, in db: Database,
  ) throws -> TranscriptHistoryPage {
    let progress = try readyClaudeHistory(key, generation: generation, in: db)
    if (before != nil || expectedEpoch != nil), expectedEpoch != progress.epoch {
      throw TranscriptHistoryError.historyChanged
    }
    let boundary = Int64(before ?? Int(progress.count))
    let rows = try ClaudeHistoryItem
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position < boundary }
      .order { $0.position.desc() }.limit(limit + 1).fetchAll(db)
    let selected = Array(rows.prefix(limit).reversed())
    let entries = try selected.map { try claudeHistoryEntry($0, in: db) }
    let loaded = Set(selected.map(\.position))
    let originPositions = Set(selected.compactMap(\.origin)).subtracting(loaded).sorted()
    let origins = try originPositions.map { position in
      guard let row = try ClaudeHistoryItem
        .where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.eq(position) }).fetchOne(db)
      else { preconditionFailure("Claude history origin is absent from its ready projection") }
      return try claudeHistoryEntry(row, in: db)
    }
    return TranscriptHistoryPage(
      generation: Int(generation), entries: entries, origins: origins,
      before: entries.first?.position ?? before, hasEarlier: rows.count > limit,
      headPosition: progress.count > 0 ? Int(progress.count - 1) : nil, historyEpoch: progress.epoch,
    )
  }

  static func claudeCodeHistoryAfter(
    _ key: String, generation: Int64, after: Int, epoch: String? = nil, in db: Database,
  ) throws -> TranscriptPage {
    let reset = TranscriptPage(generation: Int(generation), startPosition: 0, items: [], reset: true)
    let progress: ClaudeHistoryProgress
    do { progress = try readyClaudeHistory(key, generation: generation, in: db) }
    catch TranscriptHistoryError.preparing { return reset }
    guard epoch == progress.epoch, after >= -1, Int64(after) < progress.count else { return reset }
    let rows = try ClaudeHistoryItem
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position > Int64(after) }
      .order(by: \.position).limit(201).fetchAll(db)
    guard rows.count <= 200 else { return reset }
    return TranscriptPage(
      generation: Int(generation), startPosition: after + 1,
      items: try rows.map { try claudeHistoryEntry($0, in: db).item }, reset: false,
    )
  }

  private static func claudeHistoryEntry(_ row: ClaudeHistoryItem, in db: Database) throws -> TranscriptHistoryEntry {
    var item = try decode(TranscriptItem.self, from: row.payload)
    if let callID = row.callID, case var .toolResult(result) = item,
       let receipt = try receipt(row.sessionID, toolCallID: callID, in: db)
    {
      result.payload = receipt
      item = .toolResult(result)
    }
    return TranscriptHistoryEntry(position: Int(row.position), item: item)
  }

  static func discardClaudeHistory(_ key: String, generation: Int64, in db: Database) throws {
    try ClaudeHistoryProgress.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.delete().execute(db)
    try ClaudeHistoryItem.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.delete().execute(db)
    try ClaudeHistorySeen.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.delete().execute(db)
    try ClaudeHistoryCall.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.delete().execute(db)
  }

  static func invalidateClaudeHistoryHandover(_ key: String, entry: String, in db: Database) throws {
    let generation = try runtime(key, in: db).generation
    if try ClaudeHistorySeen.where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.uuid.eq(entry) }).fetchOne(db) != nil {
      try discardClaudeHistory(key, generation: generation, in: db)
    } else {
      let head = try claudeHistoryHandoverHead(key, in: db)
      try ClaudeHistoryProgress.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
        .update { $0.handoverHead = #bind(head) }.execute(db)
    }
  }
}
