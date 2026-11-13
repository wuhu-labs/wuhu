#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID

/// A handler slot as its observer cell finds it.
public struct ObserverSlot: Sendable {
  public let subscription: ArmedSubscription
  /// The input no firing has taken yet, and the rows marker it carries.
  public let pending: JSONValue?
  public let pendingMarker: String?
  /// Nil once its owner can no longer act: an archived session, a removed group.
  public let group: GroupID?
  /// Its firings that failed since the last one that did not.
  public let failures: Int

  /// The firing in progress.
  public var firing: UUID? { subscription.slot.firing }

  public init(subscription: ArmedSubscription, pending: JSONValue?, pendingMarker: String?, group: GroupID?, failures: Int) {
    self.subscription = subscription
    self.pending = pending
    self.pendingMarker = pendingMarker
    self.group = group
    self.failures = failures
  }
}

/// What a firing that ended well does to its slot.
public enum ObserverAdvance: Hashable, Sendable {
  /// The input was taken: rows up to `marker`, or, with none, a stream's event.
  case taken(marker: String?)
  case reschedule(Date)
  case retire
}

public enum HandlerOutcome: Hashable, Sendable, Codable {
  case ok(wakes: [String])
  case failed(String)
}
