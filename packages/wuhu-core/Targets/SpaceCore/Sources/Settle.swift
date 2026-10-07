#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

extension Sessions {
  // The fold's event source: what the session was shown (drained queue rows)
  // interleaved with what it posted. An undrained row is not yet seen and does
  // not open an owe the session could not have answered.
  static func settleEvents(_ key: String, through: Date = .distantFuture, after boundary: GenerationHead.SettleBoundary? = nil, in db: Database) throws -> [SettleEvent] {
    var events: [SettleEvent] = []
    for row in try Row.fetchAll(
      db,
      // Rows from the retired direct input path settle nothing and no longer decode.
      sql: """
      SELECT payload, drained_at FROM session_queue
      WHERE session_id = ? AND id > ? AND drained_at IS NOT NULL AND payload NOT LIKE '{"direct":%'
      ORDER BY id
      """,
      arguments: [key, boundary?.queueTail ?? 0],
    ) {
      let drainedAt = try SQLiteDateFormat.date(from: row["drained_at"])
      guard drainedAt <= through, var event = try decode(QueueInput.self, from: row["payload"]).settleEvent else { continue }
      if case var .delivered(delivered) = event {
        delivered.at = drainedAt
        event = .delivered(delivered)
      }
      events.append(event)
    }
    for record in try Conversations.fetch(db, where: "sender_session_id = ? AND n > ?", arguments: [key, boundary?.messageTail ?? 0]) where record.createdAt <= through {
      events.append(.posted(.init(
        conversation: record.conversation,
        kind: record.kind,
        request: record.requestID,
        at: record.createdAt,
      )))
    }
    events.sortByTime()
    return events
  }

  static func settleState(_ key: String, through: Date = .distantFuture, in db: Database) throws -> SettleState {
    let checkpoint = try settleCheckpoint(key, through: through, in: db)
    var state = checkpoint?.settle ?? SettleState()
    for event in try settleEvents(key, through: through, after: checkpoint?.settleBoundary, in: db) {
      state.apply(event)
    }
    return state
  }

  private static func settleCheckpoint(_ key: String, through: Date, in db: Database) throws -> GenerationHead? {
    let heads = try String.fetchAll(
      db,
      sql: """
      SELECT c.payload FROM session_pointers p
      JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
      WHERE p.session_id = ? AND p.position = 0
      ORDER BY p.generation DESC
      """,
      arguments: [key],
    )
    for payload in heads {
      guard let item = try? decode(TranscriptItem.self, from: payload),
            case let .generationHead(head) = item,
            head.timestamp <= through,
            head.settle != nil, head.settleBoundary != nil
      else { continue }
      return head
    }
    return nil
  }

  // A head the store wrote (creation, restart, or any head from before
  // compactions recorded one) takes its settle state from what the store saw
  // drained and posted up to the head.
  static func kernelTranscript(_ key: String, in db: Database) throws -> Transcript {
    var transcript = try Sessions.transcript(key, in: db)
    if case var .generationHead(head)? = transcript.items.first, head.settle == nil {
      head.settle = try settleState(key, through: head.timestamp, in: db)
      transcript.items[0] = .generationHead(head)
    }
    return transcript
  }
}

extension SessionStore {
  public func settleState(_ id: SessionID) async throws -> SettleState {
    let key = id.rawValue
    return try await writer.read { db in
      _ = try Sessions.record(key, in: db)
      return try Sessions.settleState(key, in: db)
    }
  }
}
