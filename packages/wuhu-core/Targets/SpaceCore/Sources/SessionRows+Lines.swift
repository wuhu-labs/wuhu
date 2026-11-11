import GRDB
import SessionDomain
import StructuredQueries

extension SessionRows {
  public func record(_ id: SessionID) throws -> SessionRecord {
    try Sessions.record(id.rawValue, in: db)
  }

  /// The session's current generation and the position of its last line there, -1 for none.
  public func lineEnd(_ id: SessionID) throws -> TranscriptCursor {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    let last = try SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db)
    return TranscriptCursor(generation: Int(generation), position: last.map { Int($0) } ?? -1)
  }

  /// The generation's lines past `after`, with its prompt lines wherever they stand when `prompt` says so, in position order.
  public func lines(_ id: SessionID, generation: Int, after: Int, prompt: Bool = false) throws -> [StoredTranscriptLine] {
    let keys = prompt ? Sessions.promptKeys : []
    return try SessionLineRow
      .where { $0.sessionID.eq(id.rawValue) && $0.generation.eq(Int64(generation)) && ($0.position.gt(Int64(after)) || $0.key.in(keys)) }
      .order(by: \.position).fetchAll(db).map(StoredTranscriptLine.init(row:))
  }
}

extension Sessions {
  /// The lines of a generation's prompt, which the inference writes into its first positions after later lines may already stand.
  static let promptKeys = ["system"] + openingKeys
}

extension StoredTranscriptLine {
  public var isPrompt: Bool {
    Sessions.promptKeys.contains(key)
  }

  init(row: SessionLineRow) {
    self.init(
      position: Int(row.position), at: try! SQLiteDateFormat.date(from: row.at), role: TranscriptLine.Role(rawValue: row.role)!,
      key: row.key, message: row.message, meta: row.meta,
    )
  }
}

extension SessionStore {
  /// The generation's last `limit` lines before position `before`, or its newest, in position order; no generation names the current one. `hasEarlier` says lines before the page remain.
  public func lines(_ id: SessionID, generation: Int?, before: Int?, limit: Int) async throws -> (generation: Int, lines: [StoredTranscriptLine], hasEarlier: Bool) {
    let key = id.rawValue
    return try await writer.read { db in
      let generation = try generation.map { Int64($0) } ?? Sessions.runtime(key, in: db).generation
      let rows = try SessionLineRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.lt(Int64(before ?? .max)) }
        .order { $0.position.desc() }.limit(limit + 1).fetchAll(db)
      return (Int(generation), rows.prefix(limit).reversed().map(StoredTranscriptLine.init(row:)), rows.count > limit)
    }
  }
}
