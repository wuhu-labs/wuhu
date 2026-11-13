import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.Arming
import struct SpaceCore.ObserverTerms
import struct SpaceCore.SessionStore
import struct SpaceCore.SubscriptionSlot
import Wuwei

extension SessionStore {
  @discardableResult
  public func armSubscription(
    _ id: SessionID,
    slot: SubscriptionSlot,
    name: String? = nil,
    nextFireAt: Date? = nil,
    marker: String? = nil,
  ) async throws -> ArmedSubscription {
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    let at = now
    let arming = Arming(slot.prepared(uuid: { uuid() }), name: name, nextFireAt: nextFireAt, marker: marker)
    return try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.armSubscription(arming, at: at) }
  }

  @discardableResult
  public func armObserver(
    _ group: GroupID,
    _ terms: ObserverTerms,
    slot: SubscriptionSlot,
    nextFireAt: Date? = nil,
    marker: String? = nil,
  ) async throws -> ArmedSubscription {
    try await space.worker.call(ObserverCell.ID(.group(group), SubscriptionID(terms.name))) {
      try $0.arm(terms, slot: slot, nextFireAt: nextFireAt, marker: marker)
    }
  }

  @discardableResult
  public func cancelObserver(_ group: GroupID, name: String) async throws -> ArmedSubscription {
    try await space.worker.call(ObserverCell.ID(.group(group), SubscriptionID(name))) { try $0.cancelObserver() }
  }

  public func armedSubscriptions(_ id: SessionID) async throws -> [ArmedSubscription] {
    try space.worker.cell(SessionCell.ID(id.rawValue)).armedSubscriptions()
  }
}
