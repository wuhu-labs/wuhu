#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

extension Sessions {
  /// When the work at hand should give the turn back to what waits for the session: each due input it has not seen allows a grace from when it came due, a person's message to the session itself 10 s, anything else 90 s; the session's own context deliveries allow none of their own. Nil while nothing waits.
  public static func yieldDeadline(_ key: String, at now: String, in db: Database) throws -> Date? {
    var deadline: Date?
    let tail = try runtime(key, in: db).queueTail
    for row in db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(tail) && ($0.dueAt.is(nil) || $0.dueAt.lte(Optional(now))) }.order { $0.id }) {
      guard let grace = try grace(of: try decode(QueueInput.self, from: row.payload), to: key, in: db) else { continue }
      let end = try SQLiteDateFormat.date(from: row.dueAt ?? row.enqueuedAt).addingTimeInterval(grace)
      deadline = min(deadline ?? end, end)
    }
    return deadline
  }

  private static func grace(of input: QueueInput, to session: String, in db: Database) throws -> TimeInterval? {
    switch input {
    case let .message(message):
      guard message.senderSession == nil,
            let conversation = try Conversations.record(message.conversationID.rawValue, in: db)
      else { return 90 }
      switch conversation.kind {
      case .box: return conversation.ownerSession?.rawValue == session ? 10 : 90
      case .dmUser: return 10
      case .users, .dmSession: return 90
      }
    case let .notification(notification):
      return notification.kind == .context ? nil : 90
    }
  }
}

extension Sessions {
  public static func hydrate(_ key: String, at now: String, in db: Database) throws -> SessionHydration {
    let record = try Sessions.record(key, in: db)
    let runtime = try Sessions.runtime(key, in: db)
    return SessionHydration(
      generation: Int(runtime.generation),
      record: record,
      legacy: try !record.executor.isRetired && Sessions.isLegacy(key, generation: runtime.generation, in: db),
      queueHead: Int(Sessions.queueHead(key, tail: runtime.queueTail, at: now, in: db)),
      queueTail: Int(runtime.queueTail),
      stepTry: Int(runtime.stepTry),
    )
  }
}
