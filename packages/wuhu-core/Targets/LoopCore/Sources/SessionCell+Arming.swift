#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.Arming
import enum SpaceCore.ObservationMail
import func SpaceCore.observationProgress
import func SpaceCore.observationToken
import enum SpaceCore.Observed
import struct SpaceCore.SessionPut
import enum SpaceCore.Sessions
import struct SpaceCore.SessionStore
import struct SpaceCore.SubscriptionRow
import struct SpaceCore.SubscriptionSlot
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func arm(_ id: SessionID, _ arming: Arming, uuid: () -> UUID) throws {
    precondition(arming.slot.handler == nil, "a handler slot is armed by its observer")
    let key = id.rawValue
    if case let .timer(schedule, message) = arming.slot.kind {
      guard let due = arming.nextFireAt else { preconditionFailure("a timer is armed with its first firing") }
      try insertInput(key, Sessions.timerPut(key, id: arming.slot.id, schedule: schedule, message: message, due: due), nowDate: now())
      return
    }
    var prepared = arming
    prepared.slot = arming.slot.prepared(uuid: uuid)
    _ = try armSubscription(prepared, at: now())
  }

  mutating func retire(_ id: SessionID, _ subscription: SubscriptionID) throws {
    if subscription == SubscriptionSlot.childrenID, let row = try SubscriptionRow.find(id.rawValue, subscription.rawValue, in: db) {
      let slot = try ArmedSubscription(row: row).observationSlot
      ctx.send(.unwatch(slot), to: ObservationMail.recipient)
    }
    try SubscriptionRow.delete(.session(id), subscription.rawValue, in: &db)
  }

  @discardableResult
  mutating func observed(_ id: SessionID, _ subscription: SubscriptionID, token: UUID, _ observed: Observed) throws -> Observed.Outcome {
    let key = id.rawValue
    guard let row = try SubscriptionRow.find(key, subscription.rawValue, in: db) else { return .ignored }
    guard try SessionStore.actingGroup(of: .session(id), in: db) != nil else {
      try retire(SessionID(key), subscription)
      return .ended
    }
    let current = try ArmedSubscription(row: row)
    guard current.slot.kind.observes, token == observationToken(current) else { return .ignored }
    let slot = SubscriptionRow.of(.session(id)).where { $0.subscriptionID.eq(subscription.rawValue) }
    func notice(_ id: UUID, _ text: String, ends: Bool) -> QueueInput {
      .notification(SystemNotification(id: id, timestamp: now(), kind: .spaceObservation, subscriptionID: subscription, endsSubscription: ends, content: .init(text: text)))
    }
    switch observed {
    case let .quiet(marker):
      try db.execute(slot.update { $0.marker = #bind(marker) })
    case let .failed(text):
      try put(id, SessionPut(notice(UUID.deterministic("observe-error", key, subscription.rawValue), text, ends: true)))
      try retire(SessionID(key), subscription)
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
      let (payload, fired) = (try Sessions.encode(advanced), rowNow)
      try db.execute(slot.update {
        $0.payload = #bind(payload)
        $0.marker = #bind(marker)
        $0.lastFiredAt = #bind(fired)
      })
    }
    return .stands
  }
}
