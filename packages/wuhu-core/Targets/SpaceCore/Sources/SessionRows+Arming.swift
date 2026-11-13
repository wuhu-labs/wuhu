#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

/// A slot a session's tool call arms, as main checked it.
public struct Arming: Hashable, Codable, Sendable {
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
  /// A plain slot of the session's own: a timer is its first firing on the session's queue, a query a row of `subscription_slots`. A plain stream is not armed here (the session's cell runs it as a job), and a handler slot is its observer's (`ObserverRows.arm`).
  public func arm(_ id: SessionID, _ arming: Arming, uuid: () -> UUID) throws {
    precondition(arming.slot.handler == nil, "a handler slot is armed by its observer")
    let key = id.rawValue
    if case let .timer(schedule, message) = arming.slot.kind {
      guard let due = arming.nextFireAt else { preconditionFailure("a timer is armed with its first firing") }
      try Sessions.insertInput(key, Sessions.timerPut(key, id: arming.slot.id, schedule: schedule, message: message, due: due), nowDate: store.dateGen.now, in: db)
      return
    }
    try store.armSubscription(key, slot: store.prepared(arming.slot, uuid: uuid), name: arming.name, nextFireAt: arming.nextFireAt, marker: arming.marker, now: now, in: db)
  }

  /// Ends the session's plain query.
  public func retire(_ id: SessionID, _ subscription: SubscriptionID) throws {
    try SessionStore.deleteSubscription(id.rawValue, subscription, in: db)
  }
}

/// What main saw of a session's plain slot (its `observe({sql})`, its children watch) and mails the session's cell, which writes it.
public enum Observed: Hashable, Codable, Sendable {
  /// The rows changed: `text` is what the model reads.
  case change(text: String, marker: String)
  /// A change with nothing to tell: the next one is measured from `marker`.
  case quiet(marker: String)
  /// The query can no longer run: `text` says why, and the slot ends.
  case failed(text: String)

  /// What taking it did to the slot.
  public enum Outcome: Sendable {
    /// The slot is gone or armed again since, or it has that marker already.
    case ignored
    case stands
    case ended
  }
}

extension SessionRows {
  /// Takes what main saw of the slot armed as `token`: the change goes on the slot's topic, replacing the one the model has not seen and due no sooner than the throttle past the last it saw, and the slot's marker moves; a failure ends the slot with its last notice. A session that can no longer act (archived) is told nothing: the slot ends.
  @discardableResult
  public func observed(_ id: SessionID, _ subscription: SubscriptionID, token: UUID, _ observed: Observed) throws -> Observed.Outcome {
    let key = id.rawValue
    guard let row = try SubscriptionRow.find(key, subscription.rawValue, in: db) else { return .ignored }
    guard try SessionStore.actingGroup(of: .session(id), in: db) != nil else {
      try SessionStore.deleteSubscription(key, subscription, in: db)
      return .ended
    }
    let current = try store.armedSubscription(row)
    guard current.slot.kind.observes, token == observationToken(current) else { return .ignored }
    let slot = SubscriptionRow.of(.session(id)).where { $0.subscriptionID.eq(subscription.rawValue) }
    func notice(_ id: UUID, _ text: String, ends: Bool) -> QueueInput {
      .notification(SystemNotification(id: id, timestamp: store.dateGen.now, kind: .spaceObservation, subscriptionID: subscription, endsSubscription: ends, content: .init(text: text)))
    }
    switch observed {
    case let .quiet(marker):
      try slot.update { $0.marker = #bind(marker) }.execute(db)
    case let .failed(text):
      try put(id, SessionPut(notice(UUID.deterministic("observe-error", key, subscription.rawValue), text, ends: true)))
      try SessionStore.deleteSubscription(key, subscription, in: db)
      return .ended
    case let .change(text, marker):
      guard marker != current.marker else { return .ignored }
      var advanced = current.slot
      var progress = observationProgress(current)
      progress.deliverySequence += 1
      advanced.observationProgress = progress
      let delivery = UUID.deterministic("observe", key, subscription.rawValue, progress.incarnation.uuidString.lowercased(), String(progress.deliverySequence))
      let throttle: Double = if case let .observe(_, throttleSeconds) = advanced.kind { throttleSeconds } else { 0 }
      try put(id, SessionPut(notice(delivery, text, ends: false), topic: subscription.rawValue, throttle: throttle))
      let (payload, fired) = (try Sessions.encode(advanced), now)
      try slot.update {
        $0.payload = #bind(payload)
        $0.marker = #bind(marker)
        $0.lastFiredAt = #bind(fired)
      }.execute(db)
    }
    return .stands
  }
}
