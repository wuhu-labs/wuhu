#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import StructuredQueries
import StructuredQueriesSQLite

public struct WebPushSubscriptionRegistration: Hashable, Sendable {
  public var endpoint: String
  public var recipient: String
  public var devicePublicKey: String
  public var p256dh: String
  public var auth: String
  public var vapidKeyID: String
  public var expiresAt: Date?

  public init(
    endpoint: String,
    recipient: String,
    devicePublicKey: String,
    p256dh: String,
    auth: String,
    vapidKeyID: String,
    expiresAt: Date?,
  ) {
    self.endpoint = endpoint
    self.recipient = recipient
    self.devicePublicKey = devicePublicKey
    self.p256dh = p256dh
    self.auth = auth
    self.vapidKeyID = vapidKeyID
    self.expiresAt = expiresAt
  }
}

public struct WebPushDeliveryRecord: Hashable, Sendable {
  public var endpoint: String
  public var p256dh: String
  public var auth: String
  public var vapidKeyID: String
  public var consecutiveFailures: Int
  public var notification: NotificationRecord
}

extension Space {
  public func registerWebPushSubscription(_ registration: WebPushSubscriptionRegistration) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      let newest = (try NotificationRow.select { $0.n.max() }.fetchOne(db))! ?? 0
      let existing = try WebPushSubscriptionRow.where { $0.endpoint.eq(registration.endpoint) }.fetchOne(db)
      let sameRecipient = existing?.recipient == registration.recipient
      let row = WebPushSubscriptionRow(
        endpoint: registration.endpoint, recipient: registration.recipient, devicePublicKey: registration.devicePublicKey,
        p256dh: registration.p256dh, auth: registration.auth, vapidKeyID: registration.vapidKeyID,
        notificationCursor: sameRecipient ? existing!.notificationCursor : newest,
        consecutiveFailures: 0, retryAt: nil, expiresAt: registration.expiresAt.map(SQLiteDateFormat.string(from:)),
        createdAt: sameRecipient ? existing!.createdAt : now, updatedAt: now,
      )
      try WebPushSubscriptionRow.insert { row } onConflict: { $0.endpoint } doUpdate: {
        $0.recipient = $1.recipient
        $0.devicePublicKey = $1.devicePublicKey
        $0.p256dh = $1.p256dh
        $0.auth = $1.auth
        $0.vapidKeyID = $1.vapidKeyID
        $0.notificationCursor = $1.notificationCursor
        $0.consecutiveFailures = $1.consecutiveFailures
        $0.retryAt = $1.retryAt
        $0.expiresAt = $1.expiresAt
        $0.createdAt = $1.createdAt
        $0.updatedAt = $1.updatedAt
      }.execute(db)
    }
  }

  public func removeWebPushSubscription(endpoint: String, devicePublicKey: String) async throws {
    try await writer.write { db in
      try WebPushSubscriptionRow.where { $0.endpoint.eq(endpoint) && $0.devicePublicKey.eq(devicePublicKey) }.delete().execute(db)
    }
  }

  public func dueWebPushDeliveries(at date: Date, limit: Int = 64) async throws -> [WebPushDeliveryRecord] {
    let now = SQLiteDateFormat.string(from: date)
    return try await writer.read { db in
      try WebPushSubscriptionRow
        .where { ($0.retryAt.is(nil) || $0.retryAt.lte(Optional(now))) && ($0.expiresAt.is(nil) || $0.expiresAt.gt(Optional(now))) }
        .join(NotificationRow.all) { subscription, notification in
          notification.n.eq(#sql("(SELECT MIN(candidate.n) FROM notifications candidate WHERE candidate.recipient = \(subscription.recipient) AND candidate.n > \(subscription.notificationCursor))", as: Int64.self))
        }
        .order { ($1.n, $0.endpoint) }.limit(limit)
        .select { WebPushPending.Columns(subscription: $0, notification: $1) }
        .fetchAll(db).map { row in
          WebPushDeliveryRecord(
            endpoint: row.subscription.endpoint, p256dh: row.subscription.p256dh, auth: row.subscription.auth,
            vapidKeyID: row.subscription.vapidKeyID, consecutiveFailures: row.subscription.consecutiveFailures,
            notification: NotificationRecord(row: row.notification),
          )
        }
    }
  }
}

@Selection
private struct WebPushPending {
  var subscription: WebPushSubscriptionRow
  var notification: NotificationRow
}
