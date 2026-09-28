import Foundation
import GRDB

let webPushSchemaSQL = """
CREATE TABLE IF NOT EXISTS "web_push_subscriptions" (
  "endpoint" TEXT NOT NULL PRIMARY KEY,
  "recipient" TEXT NOT NULL REFERENCES "personas" ("name"),
  "device_pubkey" TEXT NOT NULL REFERENCES "account_keys" ("pubkey") ON DELETE CASCADE,
  "p256dh" TEXT NOT NULL,
  "auth" TEXT NOT NULL,
  "vapid_key_id" TEXT NOT NULL,
  "notification_cursor" INTEGER NOT NULL,
  "consecutive_failures" INTEGER NOT NULL DEFAULT 0,
  "retry_at" TEXT,
  "expires_at" TEXT,
  "created_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "web_push_subscriptions_by_recipient"
  ON "web_push_subscriptions" ("recipient", "notification_cursor");
CREATE INDEX IF NOT EXISTS "web_push_subscriptions_by_retry"
  ON "web_push_subscriptions" ("retry_at");
"""

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
      let newest = try Int64.fetchOne(db, sql: "SELECT MAX(n) FROM notifications") ?? 0
      let existing = try Row.fetchOne(
        db,
        sql: "SELECT recipient, notification_cursor, created_at FROM web_push_subscriptions WHERE endpoint = ?",
        arguments: [registration.endpoint],
      )
      let cursor: Int64
      let createdAt: String
      if let existing, existing["recipient"] == registration.recipient {
        cursor = existing["notification_cursor"]
        createdAt = existing["created_at"]
      } else {
        cursor = newest
        createdAt = now
      }
      try db.execute(
        sql: """
        INSERT INTO web_push_subscriptions (
          endpoint, recipient, device_pubkey, p256dh, auth, vapid_key_id,
          notification_cursor, consecutive_failures, retry_at, expires_at, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)
        ON CONFLICT (endpoint) DO UPDATE SET
          recipient = excluded.recipient,
          device_pubkey = excluded.device_pubkey,
          p256dh = excluded.p256dh,
          auth = excluded.auth,
          vapid_key_id = excluded.vapid_key_id,
          notification_cursor = excluded.notification_cursor,
          consecutive_failures = 0,
          retry_at = NULL,
          expires_at = excluded.expires_at,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at
        """,
        arguments: [
          registration.endpoint, registration.recipient, registration.devicePublicKey,
          registration.p256dh, registration.auth, registration.vapidKeyID, cursor,
          registration.expiresAt.map(SQLiteDateFormat.string(from:)), createdAt, now,
        ],
      )
    }
  }

  public func removeWebPushSubscription(endpoint: String, devicePublicKey: String) async throws {
    try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM web_push_subscriptions WHERE endpoint = ? AND device_pubkey = ?",
        arguments: [endpoint, devicePublicKey],
      )
    }
  }

  public func dueWebPushDeliveries(at date: Date, limit: Int = 64) async throws -> [WebPushDeliveryRecord] {
    let now = SQLiteDateFormat.string(from: date)
    return try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM web_push_subscriptions WHERE expires_at IS NOT NULL AND expires_at <= ?",
        arguments: [now],
      )
      return try Row.fetchAll(
        db,
        sql: """
        SELECT
          s.endpoint, s.p256dh, s.auth, s.vapid_key_id, s.consecutive_failures,
          n.n, n.recipient, n.source, n.kind, n.payload, n.created_at, n.grp
        FROM web_push_subscriptions s
        JOIN notifications n ON n.n = (
          SELECT MIN(candidate.n) FROM notifications candidate
          WHERE candidate.recipient = s.recipient AND candidate.n > s.notification_cursor
        )
        WHERE s.retry_at IS NULL OR s.retry_at <= ?
        ORDER BY n.n, s.endpoint
        LIMIT ?
        """,
        arguments: [now, limit],
      ).map { row in
        WebPushDeliveryRecord(
          endpoint: row["endpoint"],
          p256dh: row["p256dh"],
          auth: row["auth"],
          vapidKeyID: row["vapid_key_id"],
          consecutiveFailures: row["consecutive_failures"],
          notification: try NotificationRecord(row: row),
        )
      }
    }
  }

  public func markWebPushDelivered(endpoint: String, notification: Int64) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try db.execute(
        sql: """
        UPDATE web_push_subscriptions
        SET notification_cursor = ?, consecutive_failures = 0, retry_at = NULL, updated_at = ?
        WHERE endpoint = ? AND notification_cursor < ?
        """,
        arguments: [notification, now, endpoint, notification],
      )
    }
  }

  public func deferWebPushDelivery(endpoint: String, until retryAt: Date) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try db.execute(
        sql: """
        UPDATE web_push_subscriptions
        SET consecutive_failures = consecutive_failures + 1, retry_at = ?, updated_at = ?
        WHERE endpoint = ?
        """,
        arguments: [SQLiteDateFormat.string(from: retryAt), now, endpoint],
      )
    }
  }

  public func removeWebPushSubscription(endpoint: String) async throws {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM web_push_subscriptions WHERE endpoint = ?", arguments: [endpoint])
    }
  }

  public nonisolated func observeWebPushChanges() -> AsyncStream<Void> {
    regionWakes([Table("notifications"), Table("web_push_subscriptions")], in: writer)
  }
}
