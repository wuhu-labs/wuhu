#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

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
