#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.Arming
import enum SpaceCore.ObservationMail
import enum SpaceCore.SessionStoreError
import struct SpaceCore.SubscriptionRow
import struct SpaceCore.SubscriptionSlot
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func armSubscription(_ arming: Arming, at now: Date) throws -> ArmedSubscription {
    guard !db.rows(SubscriptionSession.where { $0.id.eq(id.key) }).isEmpty else {
      throw SessionStoreError.unknownSession(id.key)
    }
    let row = try SubscriptionRow(owner: .session(id.session), slot: arming.slot, name: arming.name, nextFireAt: arming.nextFireAt, marker: arming.marker, armedAt: now)
    try db.execute(SubscriptionRow.insert { row } onConflict: { ($0.ownerKind, $0.owner, $0.subscriptionID) })
    return try ArmedSubscription(row: db.rows(SubscriptionRow.of(.session(id.session)).where { $0.subscriptionID.eq(arming.slot.id.rawValue) }).first!)
  }

  func armedSubscriptions() throws -> [ArmedSubscription] {
    try db.rows(SubscriptionRow.of(.session(id.session)).where { $0.subscriptionID.neq(SubscriptionSlot.childrenID.rawValue) }.order { $0.subscriptionID }).map(ArmedSubscription.init(row:))
  }

  mutating func armChildren(_ now: Date) throws {
    let slot = SubscriptionSlot.children(id.session, at: now)
    let row = try SubscriptionRow(owner: .session(id.session), slot: slot, armedAt: now)
    try db.execute(SubscriptionRow.insert { row } onConflict: { ($0.ownerKind, $0.owner, $0.subscriptionID) })
    let armed = try ArmedSubscription(row: db.rows(SubscriptionRow.of(.session(id.session)).where { $0.subscriptionID.eq(SubscriptionSlot.childrenID.rawValue) }).first!)
    ctx.send(.watch(armed.watch(recipient: id.recipient.retyped())), to: ObservationMail.recipient)
  }
}

@Table("sessions")
private struct SubscriptionSession {
  let id: String
}
