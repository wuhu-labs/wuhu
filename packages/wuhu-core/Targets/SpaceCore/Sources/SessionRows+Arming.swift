#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

/// A slot a session's tool call arms, as main checked it.
public struct Arming: Sendable {
  public var slot: SubscriptionSlot
  public var name: String?
  /// A timer's first firing.
  public var nextFireAt: Date?
  /// A query's rows as arming found them: the slot fires on what comes after.
  public var marker: String?

  public init(_ slot: SubscriptionSlot, name: String? = nil, nextFireAt: Date? = nil, marker: String? = nil) {
    self.slot = slot
    self.name = name
    self.nextFireAt = nextFireAt
    self.marker = marker
  }

  /// What the call that arms it is told.
  public var answer: ToolResultPayload {
    switch slot.kind {
    case let .observe(sql, _): .observe(.init(subscriptionID: slot.id, source: .query(sql)))
    case let .stream(url, _): .observe(.init(subscriptionID: slot.id, source: .stream(url)))
    case let .timer(schedule, message): .timer(.init(subscriptionID: slot.id, schedule: schedule, message: message))
    case .children: preconditionFailure("no call arms the children watch")
    }
  }
}

extension SessionRows {
  /// The answer the session's tool call already has.
  public func receipt(_ id: SessionID, _ call: ToolCallID) throws -> ToolResultPayload? {
    try Sessions.receipt(id.rawValue, toolCallID: call.rawValue, in: db)
  }

  public func record(_ payload: ToolResultPayload, answering call: ToolCallID, of id: SessionID) throws {
    try ToolReceipt(session: id, callID: call, payload: payload).record(now: now, in: db)
  }

  /// A plain timer is its first firing on the session's queue; any other slot is a row of `subscription_slots`. A plain stream is not armed here: the session's cell runs it as a job.
  public func arm(_ id: SessionID, _ arming: Arming, uuid: () -> UUID) throws {
    let key = id.rawValue
    if case let .timer(schedule, message) = arming.slot.kind, arming.slot.handler == nil {
      guard let due = arming.nextFireAt else { preconditionFailure("a timer is armed with its first firing") }
      try Sessions.insertInput(key, Sessions.timerPut(key, id: arming.slot.id, schedule: schedule, message: message, due: due), nowDate: store.dateGen.now, in: db)
      return
    }
    try store.armSubscription(key, slot: store.prepared(arming.slot, uuid: uuid), name: arming.name, nextFireAt: arming.nextFireAt, marker: arming.marker, now: now, in: db)
  }

  /// Ends the session's slot row or takes its plain timer off the queue, and says what it was; nil when neither holds it (a stream, the children watch, or nothing). A firing in progress runs on.
  public func disarm(_ id: SessionID, _ subscription: SubscriptionID) throws -> Subscription? {
    let key = id.rawValue
    if let row = try SubscriptionRow.find(key, subscription.rawValue, in: db) {
      guard let stored = try Sessions.decode(SubscriptionSlot.self, from: row.payload).kind.subscription else { return nil }
      try SessionStore.deleteSubscription(key, subscription, in: db)
      return stored
    }
    guard let schedule = try Sessions.pendingTimers(key, in: db).first(where: { $0.subscriptionID == subscription })?.schedule else { return nil }
    try Sessions.removeInput(key, topic: subscription.rawValue, in: db)
    return .timer(schedule)
  }
}
