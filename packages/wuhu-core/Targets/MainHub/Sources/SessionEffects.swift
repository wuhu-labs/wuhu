import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore

public struct SessionEffects: Sendable, TestDependencyKey {
  public var create: @Sendable (SessionCreation) async throws -> SessionID
  public var armObserver: @Sendable (GroupID, ObserverTerms, SubscriptionSlot, Date?, String?) async throws -> ArmedSubscription
  public var cancelObserver: @Sendable (GroupID, String) async throws -> ArmedSubscription
  public var observers: @Sendable (GroupID) async throws -> [ArmedSubscription]
  public var invalidatePromptRevision: @Sendable (SessionID) async throws -> Void

  public init(
    create: @escaping @Sendable (SessionCreation) async throws -> SessionID,
    armObserver: @escaping @Sendable (GroupID, ObserverTerms, SubscriptionSlot, Date?, String?) async throws -> ArmedSubscription,
    cancelObserver: @escaping @Sendable (GroupID, String) async throws -> ArmedSubscription,
    observers: @escaping @Sendable (GroupID) async throws -> [ArmedSubscription],
    invalidatePromptRevision: @escaping @Sendable (SessionID) async throws -> Void,
  ) {
    self.create = create
    self.armObserver = armObserver
    self.cancelObserver = cancelObserver
    self.observers = observers
    self.invalidatePromptRevision = invalidatePromptRevision
  }

  public static let testValue = Self(
    create: { _ in preconditionFailure("SessionEffects.create was not injected") },
    armObserver: { _, _, _, _, _ in preconditionFailure("SessionEffects.armObserver was not injected") },
    cancelObserver: { _, _ in preconditionFailure("SessionEffects.cancelObserver was not injected") },
    observers: { _ in preconditionFailure("SessionEffects.observers was not injected") },
    invalidatePromptRevision: { _ in preconditionFailure("SessionEffects.invalidatePromptRevision was not injected") },
  )
}
