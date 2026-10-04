#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum ClaudeStream.ClaudeCodeHandoverRecord
import struct ClaudeStream.ClaudeCodeLog
import GRDB
import JSONValue
import OrderedCollections
import SessionDomain
import StructuredQueries

let claudeCodeSchemaSQL = """
CREATE TABLE IF NOT EXISTS "claude_code_sessions" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "claude_session_id" TEXT NOT NULL,
  "pending_note" TEXT,
  "environment" TEXT
);
"""

@Table("claude_code_sessions")
struct ClaudeCodeSessionRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("claude_session_id") var claudeSessionID: String
  @Column("pending_note") var pendingNote: String?
  // The session environment as of the start of the current generation, taken
  // at the compaction boundary that opened it; nil for a generation that
  // starts empty.
  @Column("environment") var environment: String?
}

@Table("session_contents")
struct SessionContentRow {
  @Column("session_id") var sessionID: String
  @Column("id") var id: String
  @Column("payload") var payload: String
}

@Table("session_pointers")
struct SessionPointerRow {
  @Column("session_id") var sessionID: String
  @Column("generation") var generation: Int64
  @Column("position") var position: Int64
  @Column("content_id") var contentID: String
}

enum ClaudeCodeStoreError: Error, Equatable, Sendable {
  case notAClaudeCodeSession(String)
  case unreadableEntry(String)
}

extension SessionStore {
  // One transaction per mirror frame, so the database only ever holds whole
  // frames. The handover a frame confirms is recorded at its confirming entry,
  // in log order: a boundary later in the frame takes the environment with it.
  // Returns the confirming entry's uuid.
  @discardableResult
  public func appendClaudeCodeMirror(
    _ id: SessionID,
    entries: [OrderedDictionary<String, JSONValue>],
    confirming handover: ClaudeCodeHandover? = nil,
  ) async throws -> String? {
    let key = id.rawValue
    var images: [String: [UInt8]] = [:]
    let rows = try entries.map { try ClaudeCodeRow($0, images: &images) }
    let confirming = handover.flatMap { handover in
      entries.firstIndex(where: handover.record.isRecorded).flatMap { index in
        entries[index]["uuid"]?.stringValue.map { (index: index, entry: $0, handover: handover) }
      }
    }
    var staged: [Blob] = []
    for (hash, bytes) in images {
      staged.append(try await blobs.stage(bytes, hash: hash))
    }
    try await writer.write { [staged] db in
      guard case .claudeCode = try Sessions.record(key, in: db).executor else {
        throw ClaudeCodeStoreError.notAClaudeCodeSession(key)
      }
      for blob in staged {
        try Substrate.record(blob, in: db)
      }
      var generation = try Sessions.runtime(key, in: db).generation
      var position = Int64(try Sessions.nextPosition(key, generation: generation, in: db))
      for (index, row) in rows.enumerated() {
        var pointed = [try row.insert(key, in: db)]
        if let carried = row.carried {
          pointed = try Sessions.carriedContent(key, generation: generation, named: carried, in: db) + pointed
          // Claude Code's summary drops the environment; the generation it
          // opens starts from the value the closing one had.
          let environment = try Sessions.encode(
            Sessions.claudeCodeEnvironment(key, generation: generation, pendingSince: nil, in: db),
          )
          generation += 1
          try Sessions.openGeneration(key, generation: generation, keptCount: pointed.count, in: db)
          try ClaudeCodeSessionRow.where { $0.sessionID.eq(key) }.update { $0.environment = #bind(environment) }.execute(db)
          // The compaction moves the prompt forward; the running process keeps
          // its prompt until its next launch.
          try PromptRevisions.advance(key, in: db)
          position = 0
        }
        for contentID in pointed {
          try SessionPointerRow.insert {
            SessionPointerRow(sessionID: key, generation: generation, position: position, contentID: contentID)
          }.execute(db)
          position += 1
        }
        if let confirming, confirming.index == index {
          try Sessions.confirmClaudeCodeHandover(key, confirming.handover, entry: confirming.entry, in: db)
        }
      }
      try Sessions.maintainClaudeHistory(key, generation: generation, in: db)
    }
    return confirming?.entry
  }
}

extension Sessions {
  static func claudeCodeLog(_ key: String, in db: Database) throws -> ClaudeCodeLog {
    let generation = try Sessions.runtime(key, in: db).generation
    let payloads = try SessionPointerRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order(by: \.position)
      .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
      .select { $1.payload }
      .fetchAll(db)
    guard let stored = try ClaudeCodeSessionRow.where({ $0.sessionID.eq(key) }).select(\.claudeSessionID).fetchOne(db),
          let sessionID = UUID(uuidString: stored)
    else { preconditionFailure("Claude Code session \(key) has no Claude session id") }
    return ClaudeCodeLog(sessionID: sessionID, entries: payloads.map { payload in
      guard let entry = JSONValue.parse(payload)?.object else {
        preconditionFailure("session_contents holds a Claude Code entry that is not an object: \(payload)")
      }
      return entry
    })
  }
}

extension SessionStore {
  func restoringImages(_ log: ClaudeCodeLog) async throws -> ClaudeCodeLog {
    var hashes: Set<String> = []
    for entry in log.entries {
      _ = ClaudeCodeImages.rewriting(entry) { string in
        if let hash = ClaudeCodeImages.hash(referencedBy: string) { hashes.insert(hash) }
        return nil
      }
    }
    guard !hashes.isEmpty else { return log }
    let base64 = try await blobs.read(writer, prefetching: { [hashes] _ in Array(hashes) }) { [hashes] db, cache in
      try Dictionary(uniqueKeysWithValues: hashes.map { hash in
        (hash, Data(try cache.blob(of: hash, in: db).content).base64EncodedString())
      })
    }
    var log = log
    log.entries = log.entries.map { entry in
      ClaudeCodeImages.rewriting(entry) { string in ClaudeCodeImages.hash(referencedBy: string).map { base64[$0]! } }
    }
    return log
  }
}

extension Sessions {
  // Every line of the closing generation whose uuid the boundary names, in order,
  // repeats included. An automatic compaction names one uuid Claude Code never
  // writes, so a name with no line carries nothing, as in Claude Code's own file.
  static func carriedContent(_ key: String, generation: Int64, named uuids: [String], in db: Database) throws -> [String] {
    let wanted = Set(uuids)
    return try SessionPointerRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order(by: \.position)
      .select(\.contentID)
      .fetchAll(db)
      .filter { wanted.contains(ClaudeCodeRow.uuid(ofContent: $0)) }
  }
}

extension ClaudeCodeImages {
  static let referencePrefix = MediaReference.blob("").url.absoluteString

  static func hash(referencedBy string: String) -> String? {
    guard string.utf8.starts(with: referencePrefix.utf8) else { return nil }
    return String(decoding: string.utf8.dropFirst(referencePrefix.utf8.count), as: UTF8.self)
  }
}

// A line is keyed by its uuid. Claude Code sometimes writes a uuid twice, both
// times before the next boundary; a repeat with other bytes is its own row,
// keyed `<uuid>/<hash>`. A line with no uuid is keyed by the hash of its bytes.
struct ClaudeCodeRow {
  let uuid: String?
  let hash: String
  let payload: String
  let carried: [String]?

  static func uuid(ofContent id: String) -> String {
    String(id.prefix { $0 != "/" })
  }

  init(_ entry: OrderedDictionary<String, JSONValue>, images: inout [String: [UInt8]]) throws {
    uuid = entry["uuid"]?.stringValue
    hash = Substrate.blobHash(Array(JSONValue.object(entry).jsonString().utf8))
    carried = try Self.carried(by: entry, id: uuid ?? hash)
    let stored = ClaudeCodeImages.rewriting(entry) { string in
      guard let bytes = Data(base64Encoded: string), bytes.base64EncodedString() == string else { return nil }
      let hash = Substrate.blobHash(Array(bytes))
      images[hash] = Array(bytes)
      return ClaudeCodeImages.referencePrefix + hash
    }
    payload = JSONValue.object(stored).jsonString()
  }

  private static func carried(by entry: OrderedDictionary<String, JSONValue>, id: String) throws -> [String]? {
    guard entry["type"] == .string("system"), entry["subtype"] == .string("compact_boundary") else { return nil }
    guard let metadata = entry["compactMetadata"]?.object else {
      throw ClaudeCodeStoreError.unreadableEntry("compact boundary \(id) has no compactMetadata")
    }
    guard let preserved = metadata["preservedMessages"] else { return [] }
    let unreadable = ClaudeCodeStoreError.unreadableEntry("compact boundary \(id) has unreadable preservedMessages.allUuids")
    guard let all = preserved.object?["allUuids"]?.array else { throw unreadable }
    return try all.map { uuid in
      guard let uuid = uuid.stringValue else { throw unreadable }
      return uuid
    }
  }

  func insert(_ key: String, in db: Database) throws -> String {
    guard let uuid else { return try insertUnlessTaken(key, id: hash, in: db)! }
    if let id = try insertUnlessTaken(key, id: uuid, in: db) { return id }
    return try insertUnlessTaken(key, id: "\(uuid)/\(hash)", in: db)!
  }

  // Nil when the id already holds other bytes.
  private func insertUnlessTaken(_ key: String, id: String, in db: Database) throws -> String? {
    if let existing = try SessionContentRow
      .where({ $0.sessionID.eq(key) && $0.id.eq(id) })
      .select(\.payload)
      .fetchOne(db)
    {
      return existing == payload ? id : nil
    }
    try SessionContentRow.insert { SessionContentRow(sessionID: key, id: id, payload: payload) }.execute(db)
    return id
  }
}
