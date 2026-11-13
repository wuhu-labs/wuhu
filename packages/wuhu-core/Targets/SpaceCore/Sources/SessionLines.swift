#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import WuhuAI
import Wuwei
import WuweiQueries

// A generation's messages as sent, written by the session's cell in the step that makes them. Positions 1 and 2 are not the transcript's: they are kept for the prompt's opening, which is stored nowhere else and written when the prompt renders.
@Table("session_lines")
public struct SessionLineRow {
  @Column("session_id") public var sessionID: String
  @Column("generation") public var generation: Int64
  @Column("position") public var position: Int64
  @Column("at") public var at: String
  @Column("role") public var role: String
  @Column("key") public var key: String
  @Column("message") public var message: String
  @Column("meta") public var meta: String?

  public init(sessionID: String, generation: Int64, position: Int64, at: String, role: String, key: String, message: String, meta: String?) {
    self.sessionID = sessionID
    self.generation = generation
    self.position = position
    self.at = at
    self.role = role
    self.key = key
    self.message = message
    self.meta = meta
  }
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
  public static func appendLines(_ key: String, generation: Int64, _ lines: some Sequence<TranscriptLine>, in db: inout Database) throws -> Int64 {
    let first = max(try lastLine(key, generation: generation, in: db) ?? 0, Int64(openingKeys.count)) + 1
    for (offset, line) in lines.enumerated() {
      try insertLine(key, generation: generation, position: first + Int64(offset), line: line, in: &db)
    }
    return first
  }

  /// The generation's transcript is an older build's typed items and was never written as lines.
  public static func isLegacy(_ key: String, generation: Int64, in db: Database) throws -> Bool {
    guard try firstTranscriptLine(key, generation: generation, in: db) == nil else { return false }
    return !db.rows(LegacyPointerRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.limit(1)).isEmpty
  }

  public static func transcriptLineCount(_ key: String, generation: Int64, in db: Database) throws -> Int {
    db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && !$0.key.in(promptKeys) }
      .asSelect().count()).first!
  }

  /// The generation's lines after its prompt's, in position order.
  public static func transcriptLines(_ key: String, generation: Int64, in db: Database) throws -> [StoredTranscriptLine] {
    try lines(key, generation: generation, in: db).filter { !$0.isPrompt }
  }

  /// The text of the generation's first line under `lineKey`.
  public static func lineText(_ key: String, generation: Int64, lineKey: String, in db: Database) throws -> (at: Date, text: String)? {
    guard let row = db.rows(SessionLineRow.where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.key.eq(lineKey) }).order(by: \.position).limit(1)).first else { return nil }
    return (try SQLiteDateFormat.date(from: row.at), try StoredTranscriptLine(row: row).line().message.text)
  }

  /// Line 0 names its preamble, the blob `/_/rendered/<rendered>`, instead of carrying it.
  public static func preambleLine(rendered: String) throws -> String {
    try encode(["rendered": rendered])
  }

  /// The keys of positions 1 and 2: the group's instructions, then the session's own.
  static let openingKeys = ["group", "session"]

  private static func firstTranscriptLine(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) && !$0.key.in(openingKeys) }
      .order { $0.position.asc() }.limit(1).select(\.position)).first
  }

  private static func lastLine(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) }
      .order { $0.position.desc() }.limit(1).select(\.position)).first
  }

  private static func insertLine(_ key: String, generation: Int64, position: Int64, line: TranscriptLine, in db: inout Database) throws {
    let row = SessionLineRow(
      sessionID: key, generation: generation, position: position, at: SQLiteDateFormat.string(from: line.at),
      role: line.role.rawValue, key: line.key, message: try encode(line.message), meta: try line.meta.map(encode),
    )
    try db.execute(SessionLineRow.insert { row })
  }

  public static func lines(_ key: String, generation: Int64, in db: Database) throws -> [StoredTranscriptLine] {
    db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.order(by: \.position)).map(StoredTranscriptLine.init(row:))
  }
}

extension SessionStore {
  public func isLegacy(_ id: SessionID, generation: Int) async throws -> Bool {
    return try spaceCell.sessionIsLegacy(id, generation: generation)
  }

  /// The session's current generation and the generations that have lines, oldest first.
  public func lineGenerations(_ id: SessionID) async throws -> (current: Int, withLines: [Int]) {
    return try spaceCell.sessionLineGenerations(id)
  }

  /// The generation's lines in position order; a generation without lines has none.
  public func lines(_ id: SessionID, generation: Int) async throws -> [StoredTranscriptLine] {
    return try spaceCell.sessionLines(id, generation: generation)
  }

  public func transcriptLineCount(_ id: SessionID) async throws -> Int {
    return try spaceCell.sessionTranscriptLineCount(id)
  }

  /// The lines a request sends after its prompt: the session's current generation's, or `generation`'s.
  public func transcriptLines(_ id: SessionID, generation: Int? = nil) async throws -> [StoredTranscriptLine] {
    return try spaceCell.sessionTranscriptLines(id, generation: generation)
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

@Table("session_pointers")
private struct LegacyPointerRow {
  @Column("session_id") let sessionID: String
  let generation: Int64
}
