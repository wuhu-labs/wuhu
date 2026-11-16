#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Wuwei

public enum OutboxDisposition: Sendable {
  case retry(Date)
  case advance
  case unsubscribe
}

struct OutboxDrain<Delivery: Sendable>: Sendable {
  var due: @Sendable (Date) async throws -> [Delivery]
  var deliver: @Sendable (Delivery) async throws -> Void
  var prepare: @Sendable (inout JobDatabase, Date) throws -> Void
  var commit: @Sendable (inout JobDatabase, Delivery) throws -> Void
  var postpone: @Sendable (inout JobDatabase, Delivery, Date) throws -> Void
  var withdraw: @Sendable (inout JobDatabase, Delivery) throws -> Void
  var disposition: @Sendable (any Error, Delivery, Date) -> OutboxDisposition
  var describe: @Sendable (Delivery) -> Logger.MetadataValue
}

public struct NotificationDeliveryClient: Sendable {
  var webPush: OutboxDrain<WebPushDeliveryRecord>
  var pushRelay: OutboxDrain<PushRelayDelivery>
  var logger: Logger

  public init(
    space: Space,
    logger: Logger,
    webPush: @escaping @Sendable (WebPushDeliveryRecord) async throws -> Void,
    webPushDisposition: @escaping @Sendable (any Error, WebPushDeliveryRecord, Date) -> OutboxDisposition,
    pushRelay: @escaping @Sendable (PushRelayDelivery) async throws -> Void,
    pushRelayDisposition: @escaping @Sendable (any Error, PushRelayDelivery, Date) -> OutboxDisposition,
  ) {
    self.logger = logger
    self.webPush = OutboxDrain(
      due: { try await space.dueWebPushDeliveries(at: $0) },
      deliver: webPush,
      prepare: { try $0.removeExpiredWebPushSubscriptions(at: $1) },
      commit: { db, delivery in try db.markWebPushDelivered(endpoint: delivery.endpoint, notification: delivery.notification.n) },
      postpone: { db, delivery, retryAt in try db.deferWebPushDelivery(endpoint: delivery.endpoint, until: retryAt) },
      withdraw: { try $0.removeWebPushSubscription(endpoint: $1.endpoint) },
      disposition: webPushDisposition,
      describe: { .string($0.endpoint) },
    )
    self.pushRelay = OutboxDrain(
      due: { try await space.duePushRelayDeliveries(at: $0) },
      deliver: pushRelay,
      prepare: { _, _ in },
      commit: { db, delivery in try db.markPushRelayAccepted(delivery.grant, notification: delivery.notification.n) },
      postpone: { db, delivery, retryAt in try db.deferPushRelayDelivery(delivery.grant, until: retryAt) },
      withdraw: { try $0.removePushRelayGrant($1.grant) },
      disposition: pushRelayDisposition,
      describe: { .string($0.grant) },
    )
  }
}
