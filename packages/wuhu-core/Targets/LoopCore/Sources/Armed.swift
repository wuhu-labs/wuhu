#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import WuweiQueries

/// A timer, an observation or a stream the session armed with a tool and has not heard the end of. Written by the session's cell with the item that arms or ends it; the cell does not read it yet. A slot that ends without an item (a handler's cancel, a script's) keeps its row, so whoever compares or reads asks the stores which rows are still registered.
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

  static func folding(_ tools: ToolExecutionState) throws -> Set<Armed> {
    Set(try tools.subscriptions.map { try Armed($0, $1, handler: tools.handlerSubscriptions.contains($0)) })
  }

  /// The slot an item arms; `handlers` are the session's slots that run one.
  static func armed(by item: TranscriptItem, handlers: Set<SubscriptionID>) throws -> Armed? {
    guard case let .toolResult(result) = item else { return nil }
    switch result.payload {
    case let .observe(observed):
      let slot: Subscription = switch observed.source {
      case let .query(sql): .observe(sql: sql)
      case let .stream(url): .stream(url)
      }
      return try Armed(observed.subscriptionID, slot, handler: handlers.contains(observed.subscriptionID))
    case let .timer(timer):
      return try Armed(timer.subscriptionID, .timer(timer.schedule), handler: handlers.contains(timer.subscriptionID))
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
