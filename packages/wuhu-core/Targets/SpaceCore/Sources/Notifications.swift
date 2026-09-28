import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID

let notificationSchemaSQL = """
CREATE TABLE IF NOT EXISTS "notifications" (
  "n" INTEGER NOT NULL PRIMARY KEY,
  "recipient" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  "created_at" TEXT NOT NULL,
  "grp" TEXT NOT NULL DEFAULT ''
);
CREATE TRIGGER IF NOT EXISTS "notifications_grp_required" BEFORE INSERT ON "notifications" WHEN NEW."grp" = ''
  BEGIN SELECT RAISE(ABORT, 'grp required: notifications'); END;
CREATE INDEX IF NOT EXISTS "notifications_by_grp" ON "notifications" ("recipient", "grp", "n");
CREATE INDEX IF NOT EXISTS "notifications_by_recipient" ON "notifications" ("recipient", "n");
CREATE INDEX IF NOT EXISTS "notifications_by_source" ON "notifications" ("recipient", "kind", "source", "n");
CREATE TABLE IF NOT EXISTS "watermarks" (
  "identity" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "last_read_n" INTEGER NOT NULL,
  PRIMARY KEY ("identity", "source")
);
"""

public enum NotificationKind: String, Hashable, Sendable, Codable {
  case conversationMessage = "conversation_message"
  case childFailed = "child_failed"
  case requestDeadline = "request_deadline"
  case sessionSettled = "session_settled"
  case sessionErrored = "session_errored"
  case sessionDisconnected = "session_disconnected"
  case contractorDisconnected = "contractor_disconnected"
}

public struct NotificationRecord: Hashable, Sendable {
  public var n: Int64
  public var recipient: String
  public var source: String
  public var kind: NotificationKind
  public var payload: String
  public var createdAt: Date
  /// The group the notification belongs to: a conversation's, or the
  /// session's. A person reads one inbox across every group.
  public var group: GroupID

  // Reads a row that selected the notification's columns, grp included.
  init(row: Row) throws {
    self.n = row["n"]
    self.recipient = row["recipient"]
    self.source = row["source"]
    self.kind = NotificationKind(rawValue: row["kind"])!
    self.payload = row["payload"]
    self.createdAt = try SQLiteDateFormat.date(from: row["created_at"])
    self.group = GroupID(rawValue: row["grp"])
  }
}

enum Notifications {
  struct ConversationPayload: Codable {
    var messageID: String
    var conversationID: String
    var sender: String
    /// The poster's group, set only when it isn't the conversation's: an
    /// outside sender.
    var senderGroup: String?
    var text: String
  }

  struct ChildFailedPayload: Codable {
    var sessionID: String
    var parent: String
    var requestID: String
    var error: String
  }

  struct RequestDeadlinePayload: Codable {
    var sessionID: String
    var parent: String
    var requestID: String
    var deadlineAt: Double
  }

  struct ErroredPayload: Codable {
    var sessionID: String
    var error: String
    var message: String?
  }

  static func conversationPayload(
    messageID: MessageID,
    conversation: ConversationID,
    sender: String,
    senderGroup: GroupID? = nil,
    text: String,
  ) throws -> String {
    try Sessions.encode(ConversationPayload(
      messageID: messageID.rawValue,
      conversationID: conversation.rawValue,
      sender: sender,
      senderGroup: senderGroup?.rawValue,
      text: text,
    ))
  }

  static func append(
    recipient: String,
    source: String,
    group: GroupID,
    kind: NotificationKind,
    payload: String,
    now: String,
    in db: Database,
  ) throws {
    try db.execute(
      sql: "INSERT INTO notifications (recipient, source, kind, payload, created_at, grp) VALUES (?, ?, ?, ?, ?, ?)",
      arguments: [recipient, source, kind.rawValue, payload, now, group.rawValue],
    )
  }

  // The distinguished owner principal (SpaceContract's ownerIdentity on the
  // wire).
  static let ownerRecipient = "owner"

  static func fireErrored(_ key: String, error: String, transcript: Transcript, now: String, in db: Database) throws {
    let payload = try Sessions.encode(ErroredPayload(
      sessionID: key,
      error: error,
      message: transcript.finalAssistantText,
    ))
    try append(
      recipient: ownerRecipient, source: key, group: Sessions.group(of: key, in: db), kind: .sessionErrored,
      payload: payload, now: now, in: db,
    )
  }
}

extension Transcript {
  var finalAssistantText: String? {
    for item in items.reversed() {
      guard case let .assistant(entry) = item else { continue }
      let texts = entry.content.compactMap { block -> String? in
        guard case let .text(text) = block else { return nil }
        return text.text
      }
      return texts.joined(separator: "\n")
    }
    return nil
  }
}

extension SessionStore {
  public func notifications(recipient: String, after n: Int64 = 0) async throws -> [NotificationRecord] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM notifications WHERE recipient = ? AND n > ? ORDER BY n",
        arguments: [recipient, n],
      ).map(NotificationRecord.init(row:))
    }
  }

  @discardableResult
  public func advanceWatermark(identity: String, source: String) async throws -> Int64 {
    try await writer.write { db in
      let newest = try Int64.fetchOne(db, sql: "SELECT MAX(n) FROM notifications") ?? 0
      try db.execute(
        sql: """
        INSERT INTO watermarks (identity, source, last_read_n) VALUES (?, ?, ?)
        ON CONFLICT (identity, source) DO UPDATE SET last_read_n = excluded.last_read_n
        """,
        arguments: [identity, source, newest],
      )
      return newest
    }
  }

  public func unreadCount(identity: String, source: String) async throws -> Int {
    try await writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
        SELECT COUNT(*) FROM notifications
        WHERE recipient = ? AND source = ?
          AND n > COALESCE((SELECT last_read_n FROM watermarks WHERE identity = ? AND source = ?), 0)
        """,
        arguments: [identity, source, identity, source],
      )!
    }
  }
}
