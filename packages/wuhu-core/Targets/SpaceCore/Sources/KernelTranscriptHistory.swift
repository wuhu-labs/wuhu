import GRDB
import SessionDomain
import StructuredQueries

@Table("session_contents")
private struct KernelHistoryContent {
  @Column("rowid") var rowID: Int64
  @Column("session_id") var sessionID: String
  var id: String
  var payload: String
}

extension Sessions {
  static func kernelHistoryOrigin(
    _ key: String, generation: Int64, resultPosition: Int64, callID: ToolCallID, in db: Database,
  ) throws -> TranscriptHistoryEntry? {
    guard let resultID = try SessionPointerRow
      .where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.eq(resultPosition) })
      .select(\.contentID).fetchOne(db),
      let resultRowID = try KernelHistoryContent.where({ $0.sessionID.eq(key) && $0.id.eq(resultID) })
      .select(\.rowID).fetchOne(db)
    else { return nil }

    // Compaction reuses an ordered contiguous source range but inserts its head later.
    // Seek before the result's immutable source row, never before the new head or page start.
    guard let candidateID = try KernelHistoryContent
      .where({ $0.sessionID.eq(key) && $0.rowID < resultRowID })
      .where({ #sql("json_type(\($0.payload), '$.assistant') IS NOT NULL", as: Bool.self) })
      .order(by: { $0.rowID.desc() }).limit(1).select(\.id).fetchOne(db),
      let position = try SessionPointerRow
      .where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.contentID.eq(candidateID) && $0.position < resultPosition })
      .order(by: \.position).limit(1).select(\.position).fetchOne(db),
      let payload = try KernelHistoryContent.where({ $0.sessionID.eq(key) && $0.id.eq(candidateID) })
      .select(\.payload).fetchOne(db)
    else { return nil }
    let item = try decode(TranscriptItem.self, from: payload)
    guard case let .assistant(assistant) = item,
          assistant.toolCalls.contains(where: { $0.id == callID.rawValue })
    else { return nil }
    return TranscriptHistoryEntry(position: Int(position), item: item)
  }
}
