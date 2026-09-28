#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import struct SpaceContract.SpaceURL
import SpaceCore

struct WebPushRuntime: Sendable {
  private let outbox: NotificationOutbox<WebPushDeliveryRecord>

  init(space: Space, logger: Logger, client: WebPushClient) {
    self.outbox = NotificationOutbox(
      OutboxDrain(
        due: { try await space.dueWebPushDeliveries(at: $0) },
        deliver: { try await client.send(try await render($0, space: space)) },
        commit: { try await space.markWebPushDelivered(endpoint: $0.endpoint, notification: $0.notification.n) },
        postpone: { try await space.deferWebPushDelivery(endpoint: $0.endpoint, until: $1) },
        withdraw: { try await space.removeWebPushSubscription(endpoint: $0.endpoint) },
        disposition: { error, delivery, now in
          guard let error = error as? WebPushTransportError else {
            return .retry(outboxRetryDate(header: nil, failures: delivery.consecutiveFailures, now: now))
          }
          if error.status == 404 || error.status == 410 { return .unsubscribe }
          return .retry(outboxRetryDate(
            header: error.retryAfter,
            failures: delivery.consecutiveFailures,
            now: now,
          ))
        },
        changes: { space.observeWebPushChanges() },
        describe: { .string($0.endpoint) },
      ),
      logger: logger,
    )
  }

  func run() async {
    await outbox.run()
  }

  func drain() async throws {
    try await outbox.flush()
  }
}

private func render(_ delivery: WebPushDeliveryRecord, space: Space) async throws -> WebPushMessage {
  let notification = delivery.notification
  let target: SpaceURL.Destination = switch notification.kind {
  case .conversationMessage: .conversation(notification.source)
  case .childFailed, .requestDeadline, .sessionSettled, .sessionErrored,
       .sessionDisconnected, .contractorDisconnected: .session(notification.source)
  }
  let destination = URL(string: target.percentEncodedPath)!
  let content = NotificationContent(
    notification.kind,
    payload: notification.payload,
    origin: try await NotificationOrigin(notification, space: space),
  )
  return WebPushMessage(
    endpoint: delivery.endpoint,
    p256dh: delivery.p256dh,
    auth: delivery.auth,
    vapidKeyID: delivery.vapidKeyID,
    destination: destination,
    group: notification.group.rawValue,
    title: content.singleLineTitle,
    body: content.body,
    tag: notification.source,
    topic: notification.source,
    timestamp: notification.createdAt,
  )
}
