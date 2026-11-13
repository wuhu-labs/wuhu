#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

// A handler-less session timer is its next firing on the session's queue:
// an input on the timer's topic, due when it fires. Draining a recurring one
// puts the next.
extension Sessions {
  public static func timerPut(_ key: String, id: SubscriptionID, schedule: TimerSchedule, message: String, due: Date) -> SessionPut {
    let oneShot = if case .oneShot = schedule { true } else { false }
    let notice = SystemNotification(
      id: UUID.deterministic("timer", key, id.rawValue, String(due.timeIntervalSince1970)),
      timestamp: due,
      kind: .timer,
      subscriptionID: id,
      endsSubscription: oneShot,
      schedule: schedule,
      content: .init(text: message),
    )
    return SessionPut(.notification(notice), topic: id.rawValue, due: due)
  }

  public static func pendingTimers(_ key: String, in db: Database) throws -> [SystemNotification] {
    let tail = try runtime(key, in: db).queueTail
    return try db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(tail) && !$0.topic.is(nil) }.order { $0.id }.select { $0.payload }).compactMap { payload in
      guard case let .notification(notice) = try decode(QueueInput.self, from: payload), notice.kind == .timer, notice.schedule != nil
      else { return nil }
      return notice
    }
  }
}
