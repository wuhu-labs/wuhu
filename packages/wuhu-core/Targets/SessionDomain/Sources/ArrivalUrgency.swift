#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// How directly an item waiting in a session's queue concerns the session,
/// as a running exec or run_script call counts it before giving the turn
/// back. The most urgent sorts first.
public enum ArrivalUrgency: Hashable, Sendable, Comparable, Codable {
  /// A person's message to the session itself: its own box or a DM.
  case direct
  /// Anything else: a session's message, a channel post, a notification.
  case other
}

/// The earliest item of one urgency still waiting in a session's queue, and
/// when it arrived: its grace runs from then, not from when a call sees it.
public struct PendingArrival: Hashable, Sendable, Codable {
  public var urgency: ArrivalUrgency
  public var arrivedAt: Date

  public init(urgency: ArrivalUrgency, arrivedAt: Date) {
    self.urgency = urgency
    self.arrivedAt = arrivedAt
  }
}
