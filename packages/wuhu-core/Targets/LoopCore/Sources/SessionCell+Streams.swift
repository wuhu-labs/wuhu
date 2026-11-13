#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.SessionPut
import struct SpaceCore.SessionQueueRow
import enum SpaceCore.Sessions
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func observed(_ id: SessionID, stream: SubscriptionID, url: URL, text: String, throttle: Double, ends: Bool, uuid: () -> UUID) throws {
    let key = id.rawValue
    let nowDate = now()
    let tail = try Sessions.runtime(key, in: db).queueTail
    if let row = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.topic.eq(Optional(stream.rawValue)) && $0.id.gt(tail) }).first,
       case var .notification(notice) = try Sessions.decode(QueueInput.self, from: row.payload)
    {
      notice.content.text += text
      notice.endsSubscription = ends
      let payload = try Sessions.encode(QueueInput.notification(notice).capped())
      try db.execute(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.eq(row.id) }.update { $0.payload = payload })
      return
    }
    let notice = SystemNotification(
      id: uuid(), timestamp: nowDate, kind: .spaceObservation, subscriptionID: stream, endsSubscription: ends,
      content: .init(text: ends ? text : "observed events from \(url):\n" + text),
    )
    try insertInput(key, SessionPut(.notification(notice), topic: stream.rawValue, throttle: throttle), nowDate: nowDate)
  }

  func streams(_ id: SessionID) throws -> [SubscriptionID] {
    Sessions.streams(id.rawValue, in: db).map(\.id)
  }
}
