#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.SpaceURL
import SpaceCore

func webPushDisposition(_ error: any Error, _ delivery: WebPushDeliveryRecord, _ now: Date) -> OutboxDisposition {
  guard let error = error as? WebPushTransportError else {
    return .retry(outboxRetryDate(header: nil, failures: delivery.consecutiveFailures, now: now))
  }
  if error.status == 404 || error.status == 410 { return .unsubscribe }
  return .retry(outboxRetryDate(header: error.retryAfter, failures: delivery.consecutiveFailures, now: now))
}

func render(_ delivery: WebPushDeliveryRecord, space: Space) async throws -> WebPushMessage {
  let notification = delivery.notification
  let target: SpaceURL.Destination = switch notification.kind {
  case .conversationMessage: .conversation(notification.source)
  case .sessionSettled, .sessionErrored,
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
