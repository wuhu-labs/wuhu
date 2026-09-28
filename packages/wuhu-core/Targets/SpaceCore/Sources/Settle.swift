import Foundation
import GRDB
import SessionDomain

extension Sessions {
  // The fold's event source: what the session was shown (drained queue rows)
  // interleaved with what it posted. An undrained row is not yet seen and does
  // not open an owe the session could not have answered.
  static func settleEvents(_ key: String, through: Date = .distantFuture, in db: Database) throws -> [SettleEvent] {
    var events: [SettleEvent] = []
    for row in try Row.fetchAll(
      db,
      // Rows from the retired direct input path settle nothing and no longer decode.
      sql: """
      SELECT payload, drained_at FROM session_queue
      WHERE session_id = ? AND drained_at IS NOT NULL AND payload NOT LIKE '{"direct":%'
      ORDER BY id
      """,
      arguments: [key],
    ) {
      let drainedAt = try SQLiteDateFormat.date(from: row["drained_at"])
      guard drainedAt <= through, var event = try decode(QueueInput.self, from: row["payload"]).settleEvent else { continue }
      if case var .delivered(delivered) = event {
        delivered.at = drainedAt
        event = .delivered(delivered)
      }
      events.append(event)
    }
    for record in try Conversations.fetch(db, where: "sender_session_id = ?", arguments: [key]) where record.createdAt <= through {
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
    SettleState(folding: try settleEvents(key, through: through, in: db))
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
