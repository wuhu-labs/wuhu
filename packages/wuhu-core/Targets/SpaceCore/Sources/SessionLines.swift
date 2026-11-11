import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import WuhuAI

// Lines beside the typed items, written in the same transaction and read by
// the transcript file and the mismatch check. A generation has lines only
// when it opened with them: an append to one that has none writes nothing.
// Positions 1 and 2 are not the transcript's: they are kept for the prompt's
// opening, which is stored nowhere else and written when the prompt renders.
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

@Selection private struct LinePayload {
  var position: Int64
  var payload: String
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

/// The first position where the stored lines and the render of the typed items disagree; a nil side has no line there.
public struct TranscriptLineDifference: Hashable, Sendable {
  public struct Side: Hashable, Sendable {
    public var hash: String
    public var excerpt: String
  }

  public var position: Int
  public var line: Side?
  public var render: Side?
}

extension Sessions {
  static func writeLines(_ key: String, generation: Int64, appending items: some Collection<TranscriptItem>, after count: Int, in db: Database) throws {
    let written: Int64
    let carried: [TranscriptItem]
    if count == 0 {
      (written, carried) = (Int64(openingKeys.count), [])
    } else {
      guard let last = try lastLine(key, generation: generation, in: db) else { return }
      (written, carried) = (last, try unsettledTail(key, generation: generation, before: count, in: db))
    }
    let session = SessionID(key)
    let before = Transcript.lines(session: session, items: carried).settled
    let after = Transcript.lines(session: session, items: carried + items)
    for (offset, line) in after.lines[before ..< after.settled].enumerated() {
      try insertLine(key, generation: generation, position: written + 1 + Int64(offset), line: line, in: db)
    }
  }

  /// Line 0 names its preamble, the blob `/_/rendered/<rendered>`, instead of carrying it.
  static func preambleLine(rendered: String) throws -> String {
    try encode(["rendered": rendered])
  }

  static func writePreamble(_ key: String, generation: Int64, rendered: String, opening: PromptOpening?, at: Date, in db: Database) throws {
    guard try opening != nil || lastLine(key, generation: generation, in: db) != nil else { return }
    let row = SessionLineRow(
      sessionID: key, generation: generation, position: 0, at: SQLiteDateFormat.string(from: at),
      role: TranscriptLine.Role.system.rawValue, key: "system", message: try preambleLine(rendered: rendered), meta: nil,
    )
    try SessionLineRow.insert { row } onConflict: { ($0.sessionID, $0.generation, $0.position) }.execute(db)
    guard let opening else { return }
    for (offset, text) in [opening.group, opening.session].enumerated() where !text.isEmpty {
      let line = TranscriptLine(at: at, key: openingKeys[offset], message: .user(.init(content: [.text(text)])))
      try insertLine(key, generation: generation, position: Int64(offset + 1), line: line, in: db)
    }
  }

  /// The keys of positions 1 and 2: the group's instructions, then the session's own.
  static let openingKeys = ["group", "session"]

  /// Whether the generation leaves positions 1 and 2 to the opening: one opened before they existed starts its transcript at 1 or has items and no lines.
  static func keepsOpening(_ key: String, generation: Int64, in db: Database) throws -> Bool {
    let first = try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) && !$0.key.in(openingKeys) }
      .order { $0.position.asc() }.limit(1).select(\.position).fetchOne(db)
    return try first.map { $0 == Int64(openingKeys.count + 1) } ?? (nextPosition(key, generation: generation, in: db) == 0)
  }

  /// The opening's texts as stored, in position order; a generation that kept no room for it has none.
  static func opening(_ key: String, generation: Int64, in db: Database) throws -> [String] {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.key.in(openingKeys) && $0.position.lte(Int64(openingKeys.count)) }
      .order { $0.position.asc() }.select(\.message).fetchAll(db).map { message in
        guard case let .user(user) = try decode(Message.self, from: message), case let .text(text)? = user.content.first else {
          preconditionFailure("an opening line is one user-role text")
        }
        return text.text
      }
  }

  private static func lastLine(_ key: String, generation: Int64, in db: Database) throws -> Int64? {
    try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) }
      .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db)
  }

  // Everything before the tail's first item is settled: rendering from an
  // item that flushes held notices reproduces the generation's lines from there.
  private static func unsettledTail(_ key: String, generation: Int64, before end: Int, in db: Database) throws -> [TranscriptItem] {
    var tail: [TranscriptItem] = []
    var boundary = Int64(end)
    while true {
      let page = try SessionPointerRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position < boundary }
        .order { $0.position.desc() }.limit(16)
        .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
        .select { LinePayload.Columns(position: $0.position, payload: $1.payload) }
        .fetchAll(db)
      for row in page {
        let item = try decode(TranscriptItem.self, from: row.payload)
        tail.append(item)
        if !item.holdsNotices { return tail.reversed() }
      }
      guard let last = page.last, page.count == 16 else { return tail.reversed() }
      boundary = last.position
    }
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

  /// Compares the generation's stored lines with what a request over `transcript` sends; lines the render has not reached yet do not count, and a generation without lines has no difference.
  public func lineDifference(_ id: SessionID, generation: Int, rendered preamble: String, transcript: Transcript) async throws -> TranscriptLineDifference? {
    let stored = try await lines(id, generation: generation)
    guard !stored.isEmpty else { return nil }
    let rendered = Transcript.lines(session: id, items: transcript.items)
    // The opening is read from its lines, so only the positions around it are compared.
    let start = stored.contains { Sessions.openingKeys.contains($0.key) } ? Sessions.openingKeys.count + 1
      : stored.first { $0.position > 0 }?.position ?? 1
    let expected = try [(0, (TranscriptLine.Role.system, "system", Sessions.preambleLine(rendered: preamble)))]
      + rendered.lines[..<rendered.settled].enumerated().map { ($0 + start, ($1.role, $1.key, try Sessions.encode($1.message))) }
    let byPosition = Dictionary(uniqueKeysWithValues: stored.map { ($0.position, $0) })
    for (position, line) in expected {
      let render = TranscriptLineDifference.Side(role: line.0, key: line.1, message: line.2)
      let line = byPosition[position].map { TranscriptLineDifference.Side(role: $0.role, key: $0.key, message: $0.message) }
      if line != render { return .init(position: position, line: line, render: render) }
    }
    return nil
  }
}

extension TranscriptLineDifference.Side {
  init(role: TranscriptLine.Role, key: String, message: String) {
    hash = hexEncoded(SHA256.hash(data: Data("\(role.rawValue)\n\(key)\n\(message)".utf8)))
    excerpt = String("\(role.rawValue) \(key) \(message)".prefix(120))
  }
}
