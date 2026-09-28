import Foundation
import GRDB

let pushRelaySchemaSQL = """
CREATE TABLE IF NOT EXISTS "push_relay_grants" (
  "grant_id" TEXT NOT NULL PRIMARY KEY,
  "endpoint" TEXT NOT NULL,
  "token" TEXT NOT NULL,
  -- Carried only so a space created before the column was dropped from the
  -- model still satisfies its own NOT NULL. Nothing reads it.
  "platform" TEXT NOT NULL,
  "recipient" TEXT NOT NULL REFERENCES "personas" ("name"),
  "device_pubkey" TEXT NOT NULL REFERENCES "account_keys" ("pubkey") ON DELETE CASCADE,
  "notification_cursor" INTEGER NOT NULL,
  "consecutive_failures" INTEGER NOT NULL DEFAULT 0,
  "retry_at" TEXT,
  "created_at" TEXT NOT NULL,
  "updated_at" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "push_relay_grants_by_recipient"
  ON "push_relay_grants" ("recipient", "notification_cursor");
CREATE INDEX IF NOT EXISTS "push_relay_grants_by_retry"
  ON "push_relay_grants" ("retry_at");
"""

public struct PushRelayGrant: Hashable, Sendable {
  public var grant: String
  public var endpoint: String
  public var token: String
  public var recipient: String
  public var devicePublicKey: String

  public init(
    grant: String,
    endpoint: String,
    token: String,
    recipient: String,
    devicePublicKey: String,
  ) {
    self.grant = grant
    self.endpoint = endpoint
    self.token = token
    self.recipient = recipient
    self.devicePublicKey = devicePublicKey
  }
}

public struct PushRelayDelivery: Hashable, Sendable {
  public var grant: String
  public var endpoint: String
  public var token: String
  public var consecutiveFailures: Int
  public var notification: NotificationRecord
  // A conversation notification names the conversation, but the app opens
  // sessions; resolving the owning session here is what lets a tap land on the
  // page the message is actually on.
  public var ownerSession: String?
  public var unreadConversations: Int
}

// A grant id is opaque but not secret. Without this, any other enrolled key
// could take over an existing grant by naming it — repointing a device's
// notifications at itself, or simply destroying them.
public struct PushRelayGrantOwnedElsewhere: Error, Equatable, Sendable {
  public var grant: String
}

extension Space {
  public func registerPushRelayGrant(_ grant: PushRelayGrant) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      let newest = try Int64.fetchOne(db, sql: "SELECT MAX(n) FROM notifications") ?? 0
      let existing = try Row.fetchOne(
        db,
        sql: """
        SELECT recipient, device_pubkey, notification_cursor, created_at
        FROM push_relay_grants WHERE grant_id = ?
        """,
        arguments: [grant.grant],
      )
      if let existing, existing["device_pubkey"] as String != grant.devicePublicKey {
        throw PushRelayGrantOwnedElsewhere(grant: grant.grant)
      }
      let cursor: Int64
      let createdAt: String
      if let existing, existing["recipient"] == grant.recipient {
        cursor = existing["notification_cursor"]
        createdAt = existing["created_at"]
      } else {
        cursor = newest
        createdAt = now
      }
      try db.execute(
        sql: """
        INSERT INTO push_relay_grants (
          grant_id, endpoint, token, platform, recipient, device_pubkey,
          notification_cursor, consecutive_failures, retry_at, created_at, updated_at
        ) VALUES (?, ?, ?, 'ios', ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT (grant_id) DO UPDATE SET
          endpoint = excluded.endpoint,
          token = excluded.token,
          recipient = excluded.recipient,
          device_pubkey = excluded.device_pubkey,
          notification_cursor = excluded.notification_cursor,
          consecutive_failures = 0,
          retry_at = NULL,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at
        """,
        arguments: [
          grant.grant, grant.endpoint, grant.token, grant.recipient,
          grant.devicePublicKey, cursor, createdAt, now,
        ],
      )
    }
  }

  public func removePushRelayGrant(_ grant: String, devicePublicKey: String) async throws {
    try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM push_relay_grants WHERE grant_id = ? AND device_pubkey = ?",
        arguments: [grant, devicePublicKey],
      )
    }
  }

  public func removePushRelayGrant(_ grant: String) async throws {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM push_relay_grants WHERE grant_id = ?", arguments: [grant])
    }
  }

  public func pushRelayGrants(recipient: String) async throws -> [PushRelayGrant] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
        SELECT grant_id, endpoint, token, recipient, device_pubkey
        FROM push_relay_grants WHERE recipient = ? ORDER BY grant_id
        """,
        arguments: [recipient],
      ).map { row in
        PushRelayGrant(
          grant: row["grant_id"],
          endpoint: row["endpoint"],
          token: row["token"],
          recipient: row["recipient"],
          devicePublicKey: row["device_pubkey"],
        )
      }
    }
  }

  public func duePushRelayDeliveries(at date: Date, limit: Int = 64) async throws -> [PushRelayDelivery] {
    let now = SQLiteDateFormat.string(from: date)
    return try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
        SELECT
          g.grant_id, g.endpoint, g.token, g.consecutive_failures,
          n.n, n.recipient, n.source, n.kind, n.payload, n.created_at, n.grp,
          c.owner_session,
          (
            SELECT COUNT(DISTINCT u.source) FROM notifications u
            JOIN sessions s ON s.id = u.source AND s.kind = 'agent' AND s.lifecycle != 'archived'
            WHERE u.recipient = g.recipient AND u.kind = 'conversation_message'
              AND u.n > COALESCE(
                (SELECT w.last_read_n FROM watermarks w WHERE w.identity = u.recipient AND w.source = u.source), 0
              )
          ) AS unread_conversations
        FROM push_relay_grants g
        JOIN notifications n ON n.n = (
          SELECT MIN(candidate.n) FROM notifications candidate
          WHERE candidate.recipient = g.recipient AND candidate.n > g.notification_cursor
        )
        LEFT JOIN conversations c ON c.id = n.source
        WHERE g.retry_at IS NULL OR g.retry_at <= ?
        ORDER BY n.n, g.grant_id
        LIMIT ?
        """,
        arguments: [now, limit],
      ).map { row in
        PushRelayDelivery(
          grant: row["grant_id"],
          endpoint: row["endpoint"],
          token: row["token"],
          consecutiveFailures: row["consecutive_failures"],
          notification: try NotificationRecord(row: row),
          ownerSession: row["owner_session"],
          unreadConversations: row["unread_conversations"],
        )
      }
    }
  }

  public func markPushRelayAccepted(_ grant: String, notification: Int64) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try db.execute(
        sql: """
        UPDATE push_relay_grants
        SET notification_cursor = ?, consecutive_failures = 0, retry_at = NULL, updated_at = ?
        WHERE grant_id = ? AND notification_cursor < ?
        """,
        arguments: [notification, now, grant, notification],
      )
    }
  }

  public func deferPushRelayDelivery(_ grant: String, until retryAt: Date) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try db.execute(
        sql: """
        UPDATE push_relay_grants
        SET consecutive_failures = consecutive_failures + 1, retry_at = ?, updated_at = ?
        WHERE grant_id = ?
        """,
        arguments: [SQLiteDateFormat.string(from: retryAt), now, grant],
      )
    }
  }

  public nonisolated func observePushRelayChanges() -> AsyncStream<Void> {
    regionWakes([Table("notifications"), Table("push_relay_grants")], in: writer)
  }
}
