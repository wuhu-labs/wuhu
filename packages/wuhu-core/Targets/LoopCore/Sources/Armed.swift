#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.Arming
import enum SpaceCore.ObservationMail
import StructuredQueries
import Wuwei
import WuweiQueries

/// A timer, an observation or a stream the session armed with a tool and has not heard the end of: the session's list of its slots, whoever runs them. Written by the session's cell in the step that arms it (`arm`), deleted in the step that ends it: `disarm`, the slot's last notice, or its observer saying it is gone (`ended`).
@Table("session_armed")
struct Armed: Owned, Hashable, Encodable, Sendable {
  @Column("id") var subscription: String
  /// A `Subscription` as JSON of our own making: a JSON column writes a one-shot's time as an ISO string, which does not give the same date back.
  var slot: String
  /// An observer cell runs it, and the model hears only what its handler says.
  var handler: Bool
}

extension Armed {
  init(_ id: SubscriptionID, _ slot: Subscription, handler: Bool) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    self.init(subscription: id.rawValue, slot: String(decoding: try encoder.encode(slot), as: UTF8.self), handler: handler)
  }

  var id: SubscriptionID { SubscriptionID(subscription) }

  func decoded() throws -> Subscription {
    try JSONDecoder().decode(Subscription.self, from: Data(slot.utf8))
  }

  /// A handler timer can stay silent; only a plain timer is sure to wake the model.
  var wakesModel: Bool {
    get throws {
      if case .timer = try decoded() { !handler } else { false }
    }
  }
}

extension SessionCell {
  mutating func arm(_ arming: Arming) throws -> ToolResultPayload {
    let slot = arming.slot
    if slot.handler != nil {
      ctx.send(ObserverCell.ID(.session(id.session), slot.id)).arm(arming)
    } else if case let .stream(url, throttle) = slot.kind {
      ctx.create(streamJob(slot.id), params: .init(dialer: .session(id.session), session: id.session, subscription: slot.id, url: url, throttle: throttle, owner: id.recipient.retyped()))
    } else {
      try rows.arm(id.session, arming, uuid: client.uuid)
      if case .observe = slot.kind {
        let watched = try rows.observation(id.session, slot.id)!
        ctx.send(.watch(watched.watch(recipient: id.recipient.retyped())), to: ObservationMail.recipient)
      }
    }
    if let subscription = slot.kind.subscription {
      try db.execute(Armed.where { $0.subscription.eq(slot.id.rawValue) }.delete())
      let armed = try Armed(slot.id, subscription, handler: slot.handler != nil)
      try db.execute(Armed.insert { armed })
    }
    ctx.send(id).look()
    return arming.answer
  }

  /// Ends a slot of the session's for a call of its own: its tool's, or a script's. Only its own slots are looked up, so another session's id is as unknown as a made-up one, and so is the children watch the server keeps for it. Nothing remembers a slot past its end: one that ended (a fired one-shot, a second cancel) reads like one that never was: nil. A handler slot's firing in progress runs on.
  mutating func disarm(_ subscription: SubscriptionID) throws -> ToolResultPayload? {
    if !keepsArmed { try fillArmed() }
    guard let armed = db.rows(Armed.where { $0.subscription.eq(subscription.rawValue) }).first else { return nil }
    let payload: ToolResultPayload
    switch (try armed.decoded(), armed.handler) {
    case (.timer, false):
      try rows.clear(id.session, topic: subscription.rawValue)
      payload = .cancelTimer(.init(subscriptionID: subscription))
    case (.observe, false):
      if let watched = try rows.observation(id.session, subscription) { ctx.send(.unwatch(watched.observationSlot), to: ObservationMail.recipient) }
      try rows.retire(id.session, subscription)
      payload = .cancelObservation(.init(subscriptionID: subscription))
    case (.stream, false):
      unstream(subscription)
      payload = .cancelObservation(.init(subscriptionID: subscription))
    case let (slot, true):
      ctx.send(ObserverCell.ID(.session(id.session), subscription)).cancel()
      payload = if case .timer = slot { .cancelTimer(.init(subscriptionID: subscription)) } else { .cancelObservation(.init(subscriptionID: subscription)) }
    }
    try forget(subscription)
    ctx.send(id).look()
    return payload
  }

  mutating func forget(_ subscription: SubscriptionID) throws {
    try db.execute(Armed.where { $0.subscription.eq(subscription.rawValue) }.delete())
  }

  mutating func unstream(_ subscription: SubscriptionID) {
    guard ctx.exists(streamJob(subscription)) else { return }
    ctx.send(.stop, to: streamJob(subscription))
  }

  private func streamJob(_ subscription: SubscriptionID) -> StreamJob.ID {
    .init("\(id.session.rawValue):\(subscription.rawValue)")
  }

  var keepsArmed: Bool {
    db.rows(SessionTurn.all).first?.armed == true
  }

  func armedSlots() throws -> [SubscriptionID: Subscription] {
    Dictionary(uniqueKeysWithValues: try db.rows(Armed.all).map { ($0.id, try $0.decoded()) })
  }

  /// A parked model with a plain timer armed needs no reminder: the timer wakes it.
  func armedWake() throws -> Bool {
    try db.rows(Armed.all).contains { try $0.wakesModel }
  }

  /// Lists what the stores hold and the cell has not listed, for a session from before the cell kept the rows.
  mutating func fillArmed() throws {
    let held = try rows.armedSlots(id.session)
    let listed = Set(db.rows(Armed.all).map(\.id))
    for (slot, subscription) in held.slots where !listed.contains(slot) {
      let armed = try Armed(slot, subscription, handler: held.handlers.contains(slot))
      try db.execute(Armed.insert { armed })
    }
  }
}
