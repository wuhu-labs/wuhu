#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

// A handler-less stream is a job of the session's worker, in its `streams`
// table; what it sends goes on the stream's topic, after what the model has
// not seen yet.
extension SessionRows {
  public func observed(_ id: SessionID, stream: SubscriptionID, url: URL, text: String, throttle: Double, ends: Bool, uuid: () -> UUID) throws {
    let key = id.rawValue
    let nowDate = store.dateGen.now
    let tail = try Sessions.runtime(key, in: db).queueTail
    if let row = try Row.fetchOne(
      db,
      sql: "SELECT id, payload FROM session_queue WHERE session_id = ? AND topic = ? AND id > ?",
      arguments: [key, stream.rawValue, tail],
    ), case var .notification(notice) = try Sessions.decode(QueueInput.self, from: row["payload"]) {
      notice.content.text += text
      notice.endsSubscription = ends
      try db.execute(
        sql: "UPDATE session_queue SET payload = ? WHERE session_id = ? AND id = ?",
        arguments: [try Sessions.encode(QueueInput.notification(notice).capped()), key, row["id"] as Int64],
      )
      return
    }
    let notice = SystemNotification(
      id: uuid(), timestamp: nowDate, kind: .spaceObservation, subscriptionID: stream, endsSubscription: ends,
      content: .init(text: ends ? text : "observed events from \(url):\n" + text),
    )
    try Sessions.insertInput(key, SessionPut(.notification(notice), topic: stream.rawValue, throttle: throttle), nowDate: nowDate, in: db)
  }

  public func streams(_ id: SessionID) throws -> [SubscriptionID] {
    try Sessions.streams(id.rawValue, in: db).map(\.id)
  }
}

extension Sessions {
  /// Absent until a worker has prepared its job tables.
  static func streams(_ key: String, in db: Database) throws -> [(id: SubscriptionID, url: URL)] {
    guard try db.tableExists("streams") else { return [] }
    return try Row.fetchAll(db, sql: "SELECT subscription_id, url FROM streams WHERE session_id = ? ORDER BY armed_at", arguments: [key]).compactMap { row in
      URL(string: row["url"]).map { (SubscriptionID(row["subscription_id"]), $0) }
    }
  }
}
