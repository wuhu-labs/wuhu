#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

// A handler-less session timer is its next firing on the session's queue:
// an input on the timer's topic, due when it fires. Draining a recurring one
// puts the next.
extension Sessions {
  static func timerPut(_ key: String, id: SubscriptionID, schedule: TimerSchedule, message: String, due: Date) -> SessionPut {
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

  static func putNextTimers(_ key: String, after drained: [QueueInput], now: Date, in db: Database) throws {
    for case let .notification(notice) in drained where notice.kind == .timer {
      guard let schedule = notice.schedule, let next = schedule.next(after: max(now, notice.timestamp)) else { continue }
      try insertInput(key, timerPut(key, id: notice.subscriptionID, schedule: schedule, message: notice.content.text, due: next), nowDate: now, in: db)
    }
  }

  static func pendingTimers(_ key: String, in db: Database) throws -> [SystemNotification] {
    let tail = try runtime(key, in: db).queueTail
    return try String.fetchAll(
      db,
      sql: "SELECT payload FROM session_queue WHERE session_id = ? AND id > ? AND topic IS NOT NULL ORDER BY id",
      arguments: [key, tail],
    ).compactMap { payload in
      guard case let .notification(notice) = try decode(QueueInput.self, from: payload), notice.kind == .timer, notice.schedule != nil
      else { return nil }
      return notice
    }
  }
}
