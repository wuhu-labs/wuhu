#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import WuweiQueries

/// A timer, an observation or a stream the session armed with a tool and has not heard the end of. Written by the session's cell with the item that arms or ends it. A slot that ends without an item (a handler's cancel, a script's) keeps its row, so the cell reads only the rows the stores still hold (`SessionCell.armed`).
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

  /// The slot an item arms.
  static func armed(by item: TranscriptItem) -> (id: SubscriptionID, slot: Subscription)? {
    guard case let .toolResult(result) = item else { return nil }
    switch result.payload {
    case let .observe(observed):
      return switch observed.source {
      case let .query(sql): (observed.subscriptionID, .observe(sql: sql))
      case let .stream(url): (observed.subscriptionID, .stream(url))
      }
    case let .timer(timer):
      return (timer.subscriptionID, .timer(timer.schedule))
    default:
      return nil
    }
  }

  /// The slot an item ends: a cancel's answer, or a slot's last notice.
  static func ended(by item: TranscriptItem) -> SubscriptionID? {
    switch item {
    case let .toolResult(result):
      switch result.payload {
      case let .cancelObservation(cancelled): cancelled.subscriptionID
      case let .cancelTimer(cancelled): cancelled.subscriptionID
      default: nil
      }
    case let .notification(notice):
      notice.endsSubscription ? notice.subscriptionID : nil
    default:
      nil
    }
  }
}

extension Transcript {
  /// A generation's head says what the session has armed as it opens: the `<session-state>` the model reads.
  mutating func open(armed: [SubscriptionID: Subscription]) {
    guard case var .generationHead(head)? = items.first else { return }
    head.snapshot.subscriptions = armed
    items[0] = .generationHead(head)
  }
}
