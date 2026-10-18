import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

let sessionCommandSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_commands" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "kind" TEXT NOT NULL,
  "instructions" TEXT,
  "created_at" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "session_command_tokens" (
  "session_id" TEXT NOT NULL PRIMARY KEY,
  "token" TEXT NOT NULL
);
"""

public enum SessionCommand: Hashable, Sendable, Codable {
  case compact(instructions: String?)

  var kind: String {
    switch self {
    case .compact: "compact"
    }
  }

  var instructions: String? {
    switch self {
    case let .compact(instructions): instructions
    }
  }

  init?(kind: String, instructions: String?) {
    switch kind {
    case "compact": self = .compact(instructions: instructions)
    default: return nil
    }
  }
}

@Table("session_commands")
struct SessionCommandRow: Hashable, Sendable, Codable {
  @Column("session_id", primaryKey: true) var sessionID: String
  var kind: String
  var instructions: String?
  @Column("created_at") var createdAt: String

  var command: SessionCommand? { SessionCommand(kind: kind, instructions: instructions) }

  static func find(_ key: String, in db: Database) throws -> Self? {
    try Self.where { $0.sessionID.eq(key) }.fetchOne(db)
  }
}

@Table("session_command_tokens")
struct SessionCommandTokenRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  var token: String
}

public struct CompactRequestClaim: Hashable, Sendable, Codable {
  let row: SessionCommandRow
  let token: String
  let generation: Int
  public let transcript: Transcript
  init(row: SessionCommandRow, token: String, generation: Int, transcript: Transcript) {
    self.row = row; self.token = token; self.generation = generation; self.transcript = transcript
  }
}

extension SessionStore {
  public func requestCommand(_ id: SessionID, _ command: SessionCommand) async throws {
    @Dependency(\.uuid) var uuid
    let token = SessionCommandTokenRow(sessionID: id.rawValue, token: uuid().uuidString)
    let key = id.rawValue
    let row = SessionCommandRow(sessionID: key, kind: command.kind, instructions: command.instructions, createdAt: SQLiteDateFormat.string(from: dateGen.now))
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try SessionCommandRow.upsert { row }.execute(db)
      try SessionCommandTokenRow.upsert { token }.execute(db)
    }
    signals.post(id)
  }

  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    try await writer.read { db in try Sessions.pendingCommand(id.rawValue, in: db) }
  }

  public func takeCommand(_ id: SessionID) async throws -> SessionCommand? {
    let key = id.rawValue
    return try await writer.write { db in
      guard let row = try SessionCommandRow.find(key, in: db) else { return nil }
      try Sessions.discardCommand(key, in: db)
      return row.command
    }
  }

  public func claimCompactRequest(_ id: SessionID, generation: Int) async throws -> CompactRequestClaim? {
    @Dependency(\.uuid) var uuid
    let key = id.rawValue
    let now = dateGen.now
    return try await writer.write { db in
      let runtime = try Sessions.runtime(key, in: db)
      guard runtime.generation == generation,
            try Sessions.record(key, in: db).lifecycle == .live,
            let row = try SessionCommandRow.find(key, in: db),
            case let .compact(instructions)? = row.command
      else { return nil }
      let token: SessionCommandTokenRow
      if let existing = try SessionCommandTokenRow.where({ $0.sessionID.eq(key) }).fetchOne(db) {
        token = existing
      } else {
        token = SessionCommandTokenRow(sessionID: key, token: uuid().uuidString)
        try SessionCommandTokenRow.upsert { token }.execute(db)
      }
      var transcript = try Sessions.transcript(key, in: db)
      if let instructions, !instructions.isEmpty {
        let pending = transcript.items.reversed().prefix { item in
          switch item { case .assistant, .generationHead: false; default: true }
        }
        let materialized = pending.contains { item in
          guard case let .notification(notification) = item else { return false }
          return notification.kind == .compactRequest && notification.content == MessageContent(text: instructions)
        }
        if !materialized {
          let notification = SystemNotification(id: uuid(), timestamp: now, kind: .compactRequest, subscriptionID: .compactRequest, content: MessageContent(text: instructions))
          let item = TranscriptItem.notification(notification)
          try Sessions.append(key, generation: runtime.generation, items: [item], in: db)
          transcript.append(item)
          try Sessions.refreshWork(key, transcript: transcript, now: SQLiteDateFormat.string(from: now), in: db)
        }
      }
      return CompactRequestClaim(row: row, token: token.token, generation: generation, transcript: transcript)
    }
  }
}

extension Sessions {
  static func discardCommand(_ key: String, in db: Database) throws {
    try SessionCommandRow.where { $0.sessionID.eq(key) }.delete().execute(db)
    try SessionCommandTokenRow.where { $0.sessionID.eq(key) }.delete().execute(db)
  }

  static func pendingCommand(_ key: String, in db: Database) throws -> SessionCommand? {
    try SessionCommandRow.find(key, in: db)?.command
  }

  static func completeCompactRequest(_ claim: CompactRequestClaim?, key: String, generation: Int64, in db: Database) throws {
    guard let claim else { return }
    let row = claim.row
    guard row.sessionID == key, claim.generation == generation else {
      throw CancellationError()
    }
    guard try SessionCommandTokenRow.where({ $0.sessionID.eq(key) }).fetchOne(db)?.token == claim.token else {
      return
    }
    try discardCommand(key, in: db)
  }
}
