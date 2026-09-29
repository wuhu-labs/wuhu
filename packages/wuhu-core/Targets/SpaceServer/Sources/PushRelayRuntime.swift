#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Logging
import struct SessionDomain.MessageID
import SpaceCore

// Permanent refusals from the gateway. 410 is the revocation contract: the
// device revokes its grant at the gateway, the next push is refused, and the
// grant row goes away here — the space is told, it does not decide.
private let deadGrantStatuses: Set<Int> = [401, 403, 404, 410]
// Malformed or oversized: the grant is healthy, this one notification is not.
private let unsendableStatuses: Set<Int> = [400, 413]

struct PushRelayRuntime: Sendable {
  private let outbox: NotificationOutbox<PushRelayDelivery>

  init(space: Space, logger: Logger, client: PushRelayClient) {
    self.outbox = NotificationOutbox(
      OutboxDrain(
        due: { try await space.duePushRelayDeliveries(at: $0) },
        deliver: { try await client.send(try await render($0, space: space)) },
        // A 202 is durable acceptance at the gateway and nothing more. The
        // cursor advances on it, so delivery is best effort: a dying token
        // loses whatever is already queued or deferred, and an ambiguous APNs
        // response can deliver twice. Neither at-least-once nor at-most-once.
        commit: { try await space.markPushRelayAccepted($0.grant, notification: $0.notification.n) },
        postpone: { try await space.deferPushRelayDelivery($0.grant, until: $1) },
        withdraw: { try await space.removePushRelayGrant($0.grant) },
        disposition: { error, delivery, now in
          guard let error = error as? PushRelayTransportError, let status = error.status else {
            return .retry(outboxRetryDate(header: nil, failures: delivery.consecutiveFailures, now: now))
          }
          if deadGrantStatuses.contains(status) { return .unsubscribe }
          if unsendableStatuses.contains(status) { return .skip }
          return .retry(outboxRetryDate(
            header: error.retryAfter,
            failures: delivery.consecutiveFailures,
            now: now,
          ))
        },
        changes: { space.observePushRelayChanges() },
        describe: { .string($0.grant) },
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

func render(_ delivery: PushRelayDelivery, space: Space) async throws -> PushRelayMessage {
  let notification = delivery.notification
  let payload = JSONValue.parse(notification.payload)?.object
  let content = NotificationContent(
    notification.kind,
    payload: notification.payload,
    origin: try await NotificationOrigin(notification, space: space),
  )
  var data = [
    "kind": notification.kind.rawValue,
    "source": notification.source,
    "n": String(notification.n),
    // One inbox spans every group: the notification's group (the
    // conversation's, or the session's) travels so a tap opens it there.
    "group": notification.group.rawValue,
  ]
  switch notification.kind {
  case .conversationMessage:
    data["conversation"] = notification.source
    // The app opens sessions, not conversations. Resolving the owning session
    // server-side is what makes a tap land on the right page instead of the
    // space's front door.
    data["session"] = delivery.ownerSession
    data["message"] = payload?["messageID"]?.stringValue
    if let message = payload?["messageID"]?.stringValue {
      data["senderGroup"] = try await space.sessions.message(MessageID(message))?.senderGroup.rawValue
    }
  case .childFailed, .requestDeadline, .sessionSettled, .sessionErrored,
       .sessionDisconnected, .contractorDisconnected:
    data["session"] = notification.source
  }
  if let sender = try await NotificationSender(notification, space: space) {
    data["sender"] = sender.id
    data["senderKind"] = sender.kind.rawValue
  }
  // One key per notification: iOS replaces a banner that shares a collapse id,
  // so only a retry of this same notification may replace it. Stacking by
  // conversation is the thread id's job.
  let key = "\(delivery.grant):\(notification.n)"
  return PushRelayMessage(
    endpoint: delivery.endpoint,
    token: delivery.token,
    idempotencyKey: key,
    title: content.title,
    subtitle: content.subtitle,
    body: content.body,
    threadID: notification.source,
    collapseKey: key,
    badge: delivery.unreadConversations,
    data: data.compactMapValues { $0 },
  )
}
