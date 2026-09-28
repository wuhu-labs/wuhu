#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum ClaudeStream.ClaudeCodeHandoverRecord
import struct ClaudeStream.ClaudeCodeLog
import GRDB
import JSONValue
import SessionDomain
import StructuredQueries

// The Claude Code loop's queue: rows are handed over without being drained,
// and drained only once Claude Code's mirror shows its log recorded them.
extension SessionStore {
  public func claudeCodeLog(_ id: SessionID) async throws -> ClaudeCodeLog {
    let key = id.rawValue
    return try await restoringImages(try await writer.read { db in try Sessions.claudeCodeLog(key, in: db) })
  }

  public func undrainedInputs(_ id: SessionID) async throws -> [SessionQueueEntry] {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.undrained(key, tail: try Sessions.runtime(key, in: db).queueTail, in: db)
    }
  }

  public func claudeCodePendingNote(_ id: SessionID) async throws -> String? {
    let key = id.rawValue
    return try await writer.read { db in
      try ClaudeCodeSessionRow.where { $0.sessionID.eq(key) }.select(\.pendingNote).fetchOne(db) ?? nil
    }
  }

  // A turn starting without a queue row (a continuation) still has to read as work.
  public func beginClaudeCodeTurn(_ id: SessionID) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in try Sessions.markHasWork(key, now: now, in: db) }
  }

  func confirmClaudeCodeHandover(
    _ id: SessionID,
    through queueID: Int?,
    note: Bool,
    nag: Nag? = nil,
    compactionNotice: Bool = false,
    entry: String,
    handedOverAt: Date,
  ) async throws {
    let key = id.rawValue
    let handedOver = ClaudeCodeHandover(
      record: .userEntry(uuid: entry), through: queueID, note: note, nag: nag, compactionNotice: compactionNotice, at: handedOverAt,
    )
    try await writer.write { db in try Sessions.confirmClaudeCodeHandover(key, handedOver, entry: entry, in: db) }
  }

  // Owed from the compaction boundary that opened the current generation until
  // a confirmed handover in it records the notice; nil when none is owed.
  public func claudeCodeOwedCompactionNotice(_ id: SessionID) async throws -> CompactionTrigger? {
    let key = id.rawValue
    return try await writer.read { db in
      guard try ClaudeCodeSessionRow.where({ $0.sessionID.eq(key) }).select(\.environment).fetchOne(db) ?? nil != nil else {
        return nil
      }
      let generation = try Sessions.runtime(key, in: db).generation
      let kept = try Sessions.keptCount(key, generation: generation, in: db) ?? 0
      let opening = try SessionPointerRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.eq(kept - 1) }
        .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
        .select { $1.payload }
        .fetchOne(db)
      guard let payload = opening, let boundary = JSONValue.parse(payload)?.object, boundary["subtype"] == "compact_boundary"
      else { preconditionFailure("generation \(generation) of \(key) holds an environment but opens with no boundary") }
      let shown = Set(
        try ClaudeCodeHandoverRow.where { $0.sessionID.eq(key) }.fetchAll(db)
          .filter { try Sessions.decode(ClaudeCodeHandoverEffect.self, from: $0.effect) == .compactionNotice }
          .map(\.entryUUID),
      )
      let since = try SessionPointerRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position >= kept }
        .select(\.contentID)
        .fetchAll(db)
      guard since.allSatisfy({ !shown.contains(ClaudeCodeRow.uuid(ofContent: $0)) }) else { return nil }
      return boundary["compactMetadata"]?.object?["trigger"] == "auto" ? .automatic : .manual
    }
  }

  // A finished turn leaves work only if deliveries are still queued.
  public func settleClaudeCodeTurn(_ id: SessionID) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try Sessions.refreshWork(key, transcript: Transcript(), now: now, in: db)
    }
  }
}

// One handover the loop holds unconfirmed: what it delivered, and the log
// entry that will prove Claude Code recorded it.
public struct ClaudeCodeHandover: Hashable, Sendable {
  public var record: ClaudeCodeHandoverRecord
  public var through: Int?
  public var note: Bool
  public var nag: Nag?
  public var compactionNotice: Bool
  public var at: Date

  public init(record: ClaudeCodeHandoverRecord, through: Int?, note: Bool, nag: Nag?, compactionNotice: Bool, at: Date) {
    self.record = record
    self.through = through
    self.note = note
    self.nag = nag
    self.compactionNotice = compactionNotice
    self.at = at
  }
}

public enum CompactionTrigger: Hashable, Sendable {
  case automatic
  case manual
}

extension Sessions {
  static func keptCount(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: "SELECT kept_count FROM session_generations WHERE session_id = ? AND generation = ?",
      arguments: [key, generation],
    )
  }

  // Drained as of the handover, not now: the settle fold orders what the
  // session was shown against what it posted, and it was shown at handover.
  // The confirming entry is recorded against each row, nag and notice it carried.
  static func confirmClaudeCodeHandover(_ key: String, _ handover: ClaudeCodeHandover, entry: String, in db: Database) throws {
    var effects: [ClaudeCodeHandoverEffect] = (handover.nag.map { [.nag($0)] } ?? []) + (handover.compactionNotice ? [.compactionNotice] : [])
    if let queueID = handover.through {
      let tail = try Sessions.runtime(key, in: db).queueTail
      effects += try Sessions.undrained(key, tail: tail, in: db).map(\.id).filter { $0 <= queueID }.map(ClaudeCodeHandoverEffect.queue)
      try db.execute(
        sql: "UPDATE session_runtime SET queue_tail = MAX(queue_tail, ?) WHERE session_id = ?",
        arguments: [queueID, key],
      )
      try Sessions.markDrained(key, through: Int64(queueID), now: SQLiteDateFormat.string(from: handover.at), in: db)
    }
    if handover.note {
      try ClaudeCodeSessionRow.where { $0.sessionID.eq(key) }.update { $0.pendingNote = #bind(String?.none) }.execute(db)
    }
    try Sessions.recordClaudeCodeHandover(key, entry: entry, effects: effects, at: handover.at, in: db)
  }

  static func beginClaudeCodeGeneration(_ key: String, claudeSessionID: String, note: String?, in db: Database) throws {
    try ClaudeCodeSessionRow.where { $0.sessionID.eq(key) }.delete().execute(db)
    try ClaudeCodeSessionRow.insert {
      ClaudeCodeSessionRow(sessionID: key, claudeSessionID: claudeSessionID, pendingNote: note, environment: nil)
    }.execute(db)
  }
}
