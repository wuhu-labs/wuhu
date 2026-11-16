#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import StructuredQueries
import Wuwei
import WuweiQueries

extension JobDatabase {
  public mutating func markWebPushDelivered(endpoint: String, notification: Int64) throws {
    try execute(WebPushSubscriptionRow.where { $0.endpoint.eq(endpoint) && $0.notificationCursor < notification }.update {
      $0.notificationCursor = #bind(notification)
      $0.consecutiveFailures = 0
      $0.retryAt = #bind(nil)
    })
  }

  public mutating func deferWebPushDelivery(endpoint: String, until retryAt: Date) throws {
    let retry = SQLiteDateFormat.string(from: retryAt)
    try execute(WebPushSubscriptionRow.where { $0.endpoint.eq(endpoint) }.update {
      $0.consecutiveFailures += 1
      $0.retryAt = #bind(retry)
    })
  }

  public mutating func removeWebPushSubscription(endpoint: String) throws {
    try execute(WebPushSubscriptionRow.where { $0.endpoint.eq(endpoint) }.delete())
  }

  public mutating func removeExpiredWebPushSubscriptions(at date: Date) throws {
    let now = SQLiteDateFormat.string(from: date)
    try execute(WebPushSubscriptionRow.where { $0.expiresAt.lte(Optional(now)) }.delete())
  }

  public mutating func markPushRelayAccepted(_ grant: String, notification: Int64) throws {
    try execute(PushRelayGrantRow.where { $0.grantID.eq(grant) && $0.notificationCursor < notification }.update {
      $0.notificationCursor = #bind(notification)
      $0.consecutiveFailures = 0
      $0.retryAt = #bind(nil)
    })
  }

  public mutating func deferPushRelayDelivery(_ grant: String, until retryAt: Date) throws {
    let retry = SQLiteDateFormat.string(from: retryAt)
    try execute(PushRelayGrantRow.where { $0.grantID.eq(grant) }.update {
      $0.consecutiveFailures += 1
      $0.retryAt = #bind(retry)
    })
  }

  public mutating func removePushRelayGrant(_ grant: String) throws {
    try execute(PushRelayGrantRow.where { $0.grantID.eq(grant) }.delete())
  }
}

@Table("web_push_subscriptions")
struct WebPushSubscriptionRow {
  @Column(primaryKey: true) var endpoint: String
  @Column("owner_account") var ownerAccount: String
  var recipient: String
  @Column("device_pubkey") var devicePublicKey: String
  var p256dh: String
  var auth: String
  @Column("vapid_key_id") var vapidKeyID: String
  @Column("notification_cursor") var notificationCursor: Int64
  @Column("consecutive_failures") var consecutiveFailures: Int
  @Column("retry_at") var retryAt: String?
  @Column("expires_at") var expiresAt: String?
  @Column("created_at") var createdAt: String
}

@Table("push_relay_grants")
struct PushRelayGrantRow {
  @Column("grant_id", primaryKey: true) var grantID: String
  var endpoint: String
  var token: String
  @Column("owner_account") var ownerAccount: String
  var recipient: String
  @Column("device_pubkey") var devicePublicKey: String
  @Column("notification_cursor") var notificationCursor: Int64
  @Column("consecutive_failures") var consecutiveFailures: Int
  @Column("retry_at") var retryAt: String?
  @Column("created_at") var createdAt: String
}
