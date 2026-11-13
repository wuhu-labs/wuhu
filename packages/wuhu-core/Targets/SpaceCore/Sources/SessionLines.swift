#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import WuhuAI

// A generation's messages as sent, written by the session's cell in the step that makes them. Positions 1 and 2 are not the transcript's: they are kept for the prompt's opening, which is stored nowhere else and written when the prompt renders.
@Table("session_lines")
struct SessionLineRow {
  @Column("session_id") var sessionID: String
  @Column("generation") var generation: Int64
  @Column("position") var position: Int64
  @Column("at") var at: String
  @Column("role") var role: String
  @Column("key") var key: String
  @Column("message") var message: String
  @Column("meta") var meta: String?
}

/// A line as stored: its message is the JSON the request carried, before media resolution.
public struct StoredTranscriptLine: Hashable, Sendable {
  public var position: Int
  public var at: Date
  public var role: TranscriptLine.Role
  public var key: String
  public var message: String
  public var meta: String?
}

extension StoredTranscriptLine {
  public func line() throws -> TranscriptLine {
    TranscriptLine(at: at, key: key, message: try Sessions.decode(Message.self, from: message), meta: try meta.map { try Sessions.decode(TranscriptLine.Meta.self, from: $0) })
  }
}

extension Sessions {
  /// Writes `lines` after the generation's last and returns the first position taken.
  @discardableResult
  static func appendLines(_ key: String, generation: Int64, _ lines: some Sequence<TranscriptLine>, in db: Database) throws -> Int64 {
    let first = max(try lastLine(key, generation: generation, in: db) ?? 0, Int64(openingKeys.count)) + 1
    for (offset, line) in lines.enumerated() {
      try insertLine(key, generation: generation, position: first + Int64(offset), line: line, in: db)
    }
    return first
  }

  /// The generation's transcript is an older build's typed items and was never written as lines.
  static func isLegacy(_ key: String, generation: Int64, in db: Database) throws -> Bool {
    guard try firstTranscriptLine(key, generation: generation, in: db) == nil else { return false }
    return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM session_pointers WHERE session_id = ? AND generation = ?)", arguments: [key, generation])!
  }

  static func transcriptLineCount(_ key: String, generation: Int64, in db: Database) throws -> Int {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && !$0.key.in(promptKeys) }
      .asSelect().count().fetchOne(db)!
  }

  /// The generation's lines after its prompt's, in position order.
  static func transcriptLines(_ key: String, generation: Int64, in db: Database) throws -> [StoredTranscriptLine] {
    try lines(key, generation: generation, in: db).filter { !$0.isPrompt }
  }

  /// The text of the generation's first line under `lineKey`.
  static func lineText(_ key: String, generation: Int64, lineKey: String, in db: Database) throws -> (at: Date, text: String)? {
    guard let row = try SessionLineRow.where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.key.eq(lineKey) }).order(by: \.position).limit(1).fetchOne(db) else { return nil }
    return (try SQLiteDateFormat.date(from: row.at), try StoredTranscriptLine(row: row).line().message.text)
  }

  /// Line 0 names its preamble, the blob `/_/rendered/<rendered>`, instead of carrying it.
  static func preambleLine(rendered: String) throws -> String {
    try encode(["rendered": rendered])
  }

  /// The keys of positions 1 and 2: the group's instructions, then the session's own.
  static let openingKeys = ["group", "session"]

  private static func firstTranscriptLine(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) && !$0.key.in(openingKeys) }
      .order { $0.position.asc() }.limit(1).select(\.position).fetchOne(db)
  }

  private static func lastLine(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) }
      .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db)
  }

  private static func insertLine(_ key: String, generation: Int64, position: Int64, line: TranscriptLine, in db: Database) throws {
    let row = SessionLineRow(
      sessionID: key, generation: generation, position: position, at: SQLiteDateFormat.string(from: line.at),
      role: line.role.rawValue, key: line.key, message: try encode(line.message), meta: try line.meta.map(encode),
    )
    try SessionLineRow.insert { row }.execute(db)
  }

  static func lines(_ key: String, generation: Int64, in db: Database) throws -> [StoredTranscriptLine] {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.order(by: \.position).fetchAll(db).map(StoredTranscriptLine.init(row:))
  }
}

extension SessionStore {
  public func isLegacy(_ id: SessionID, generation: Int) async throws -> Bool {
    try await writer.read { db in try Sessions.isLegacy(id.rawValue, generation: Int64(generation), in: db) }
  }

  /// The session's current generation and the generations that have lines, oldest first.
  public func lineGenerations(_ id: SessionID) async throws -> (current: Int, withLines: [Int]) {
    let key = id.rawValue
    return try await writer.read { db in
      let current = try Sessions.runtime(key, in: db).generation
      let generations = try SessionLineRow.where { $0.sessionID.eq(key) }.order(by: \.generation).select(\.generation).distinct().fetchAll(db)
      return (Int(current), generations.map { Int($0) })
    }
  }

  /// The generation's lines in position order; a generation without lines has none.
  public func lines(_ id: SessionID, generation: Int) async throws -> [StoredTranscriptLine] {
    try await writer.read { db in try Sessions.lines(id.rawValue, generation: Int64(generation), in: db) }
  }

  public func transcriptLineCount(_ id: SessionID) async throws -> Int {
    try await writer.read { db in
      try Sessions.transcriptLineCount(id.rawValue, generation: Sessions.runtime(id.rawValue, in: db).generation, in: db)
    }
  }

  /// The lines a request sends after its prompt: the session's current generation's, or `generation`'s.
  public func transcriptLines(_ id: SessionID, generation: Int? = nil) async throws -> [StoredTranscriptLine] {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.transcriptLines(key, generation: try generation.map { Int64($0) } ?? Sessions.runtime(key, in: db).generation, in: db)
    }
  }
}

extension Message {
  /// The message's text blocks, joined.
  var text: String {
    let content = switch self {
    case let .user(message): message.content
    case let .assistant(message): message.content
    case let .toolResult(message): message.content
    }
    return content.compactMap { block in
      if case let .text(text) = block { text.text } else { nil }
    }.joined(separator: "\n")
  }
}
