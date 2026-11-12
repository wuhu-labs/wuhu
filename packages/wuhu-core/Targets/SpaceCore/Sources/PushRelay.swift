#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import StructuredQueries
import StructuredQueriesSQLite

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
      let newest = (try NotificationRow.select { $0.n.max() }.fetchOne(db))! ?? 0
      let existing = try PushRelayGrantRow.where { $0.grantID.eq(grant.grant) }.fetchOne(db)
      if let existing, existing.devicePublicKey != grant.devicePublicKey {
        throw PushRelayGrantOwnedElsewhere(grant: grant.grant)
      }
      let sameRecipient = existing?.recipient == grant.recipient
      let row = PushRelayGrantRow(
        grantID: grant.grant, endpoint: grant.endpoint, token: grant.token, platform: "ios", recipient: grant.recipient,
        devicePublicKey: grant.devicePublicKey, notificationCursor: sameRecipient ? existing!.notificationCursor : newest,
        consecutiveFailures: 0, retryAt: nil, createdAt: sameRecipient ? existing!.createdAt : now, updatedAt: now,
      )
      try PushRelayGrantRow.insert { row } onConflict: { $0.grantID } doUpdate: {
        $0.endpoint = $1.endpoint
        $0.token = $1.token
        $0.recipient = $1.recipient
        $0.devicePublicKey = $1.devicePublicKey
        $0.notificationCursor = $1.notificationCursor
        $0.consecutiveFailures = $1.consecutiveFailures
        $0.retryAt = $1.retryAt
        $0.createdAt = $1.createdAt
        $0.updatedAt = $1.updatedAt
      }.execute(db)
    }
  }

  public func removePushRelayGrant(_ grant: String, devicePublicKey: String) async throws {
    try await writer.write { db in
      try PushRelayGrantRow.where { $0.grantID.eq(grant) && $0.devicePublicKey.eq(devicePublicKey) }.delete().execute(db)
    }
  }

  public func pushRelayGrants(recipient: String) async throws -> [PushRelayGrant] {
    try await writer.read { db in
      try PushRelayGrantRow.where { $0.recipient.eq(recipient) }.order { $0.grantID }.fetchAll(db).map { row in
        PushRelayGrant(grant: row.grantID, endpoint: row.endpoint, token: row.token, recipient: row.recipient, devicePublicKey: row.devicePublicKey)
      }
    }
  }

  public func duePushRelayDeliveries(at date: Date, limit: Int = 64) async throws -> [PushRelayDelivery] {
    let now = SQLiteDateFormat.string(from: date)
    return try await writer.read { db in
      try PushRelayGrantRow.where { $0.retryAt.is(nil) || $0.retryAt.lte(Optional(now)) }
        .join(NotificationRow.all) { grant, notification in
          notification.n.eq(#sql("(SELECT MIN(candidate.n) FROM notifications candidate WHERE candidate.recipient = \(grant.recipient) AND candidate.n > \(grant.notificationCursor))", as: Int64.self))
        }
        .order { ($1.n, $0.grantID) }.limit(limit)
        .select { grant, notification in
          PushRelayPending.Columns(
            grant: grant, notification: notification,
            ownerSession: #sql("(SELECT owner_session FROM conversations WHERE id = \(notification.source))", as: String?.self),
            unreadConversations: #sql("""
            (SELECT COUNT(DISTINCT u.source) FROM notifications u
             JOIN sessions s ON s.id = u.source AND s.kind = 'agent' AND s.lifecycle != 'archived'
             WHERE u.recipient = \(grant.recipient) AND u.kind = 'conversation_message'
               AND u.n > COALESCE((SELECT w.last_read_n FROM watermarks w WHERE w.identity = u.recipient AND w.source = u.source), 0))
            """, as: Int.self),
          )
        }
        .fetchAll(db).map { row in
          PushRelayDelivery(
            grant: row.grant.grantID, endpoint: row.grant.endpoint, token: row.grant.token,
            consecutiveFailures: row.grant.consecutiveFailures, notification: NotificationRecord(row: row.notification),
            ownerSession: row.ownerSession, unreadConversations: row.unreadConversations,
          )
        }
    }
  }
}

@Selection
private struct PushRelayPending {
  var grant: PushRelayGrantRow
  var notification: NotificationRow
  var ownerSession: String?
  var unreadConversations: Int
}
