#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

public enum TranscriptHistoryError: Error, Equatable, Sendable {
  case invalidPage
  case generationChanged(expected: Int, actual: Int)
  case historyChanged
  case preparing(generation: Int)
}

public struct TranscriptHistoryEntry: Hashable, Sendable {
  public var position: Int
  public var item: TranscriptItem

  public init(position: Int, item: TranscriptItem) {
    self.position = position
    self.item = item
  }
}

public struct TranscriptHistoryPage: Hashable, Sendable {
  public var generation: Int
  public var entries: [TranscriptHistoryEntry]
  public var origins: [TranscriptHistoryEntry]
  public var before: Int?
  public var hasEarlier: Bool
  public var headPosition: Int?
  public var historyEpoch: String? = nil
}

@Selection private struct HistoryPayload {
  var position: Int64
  var payload: String
}

extension SessionStore {
  public func transcriptHistory(
    _ id: SessionID,
    limit: Int = 200,
    generation expected: Int? = nil,
    before: Int? = nil,
    epoch: String? = nil,
  ) async throws -> TranscriptHistoryPage {
    guard (1 ... 200).contains(limit), before.map({ $0 >= 0 }) ?? true,
          (expected == nil) == (before == nil)
    else { throw TranscriptHistoryError.invalidPage }
    let key = id.rawValue
    return try await writer.read { db in
      let generation = try Sessions.runtime(key, in: db).generation
      if let expected, expected != Int(generation) {
        throw TranscriptHistoryError.generationChanged(expected: expected, actual: Int(generation))
      }
      if case .claudeCode = try Sessions.record(key, in: db).executor {
        return TranscriptHistoryPage(generation: Int(generation), entries: [], origins: [], before: nil, hasEarlier: false, headPosition: nil)
      }
      let headValue: Int64? = try SessionPointerRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
        .order { $0.position.desc() }.limit(1).select(\.position).fetchOne(db)
      let head = headValue.map { Int($0) }
      let boundary = Int64(before ?? ((head ?? -1) + 1))
      let matching = SessionPointerRow
        .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position < boundary }
        .order { $0.position.desc() }.limit(limit + 1)
        .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
      let selection = matching.select { HistoryPayload.Columns(position: $0.position, payload: $1.payload) }
      let rows: [HistoryPayload] = try selection.fetchAll(db)
      let entries = try rows.prefix(limit).reversed().map { row in
        TranscriptHistoryEntry(position: Int(row.position), item: try Sessions.decode(TranscriptItem.self, from: row.payload))
      }
      var origins: [TranscriptHistoryEntry] = []
      let leading = entries.prefix(while: { if case .assistant = $0.item { false } else { true } })
      if let result = leading.first(where: {
        if case let .toolResult(value) = $0.item, case .toolCall = value.provenance { true } else { false }
      }), case let .toolResult(value) = result.item, case let .toolCall(callID) = value.provenance,
      let origin = try Sessions.kernelHistoryOrigin(key, generation: generation, resultPosition: Int64(result.position), callID: callID, in: db) {
        origins = [origin]
      }
      return TranscriptHistoryPage(
        generation: Int(generation),
        entries: entries,
        origins: origins,
        before: entries.first?.position ?? before,
        hasEarlier: rows.count > limit,
        headPosition: head,
      )
    }
  }
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
