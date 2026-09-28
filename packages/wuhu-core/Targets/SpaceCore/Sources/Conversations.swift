import Crypto
import Foundation
import GRDB
import SessionDomain
import struct SpaceContract.GroupID

let conversationSchemaSQL = """
CREATE TABLE IF NOT EXISTS "conversations" (
  "id" TEXT NOT NULL PRIMARY KEY,
  "kind" TEXT NOT NULL,
  "owner_session" TEXT,
  "window_messages" INTEGER NOT NULL,
  "window_seconds" INTEGER NOT NULL,
  "created_at" TEXT NOT NULL,
  "grp" TEXT NOT NULL DEFAULT ''
);
CREATE TRIGGER IF NOT EXISTS "conversations_grp_required" BEFORE INSERT ON "conversations" WHEN NEW."grp" = ''
  BEGIN SELECT RAISE(ABORT, 'grp required: conversations'); END;
CREATE INDEX IF NOT EXISTS "conversations_by_grp" ON "conversations" ("grp");
CREATE TABLE IF NOT EXISTS "conversation_members" (
  "conversation_id" TEXT NOT NULL,
  "member" TEXT NOT NULL,
  "member_kind" TEXT NOT NULL,
  "joined_at" TEXT NOT NULL,
  PRIMARY KEY ("conversation_id", "member")
);
CREATE TABLE IF NOT EXISTS "messages" (
  "n" INTEGER NOT NULL PRIMARY KEY,
  "id" TEXT NOT NULL,
  "conversation_id" TEXT NOT NULL,
  "sender_id" TEXT NOT NULL,
  "sender_session_id" TEXT,
  "sender_timezone" TEXT NOT NULL,
  "reply_target" TEXT,
  "kind" TEXT NOT NULL,
  "request_id" TEXT,
  "deadline_at" TEXT,
  "content" TEXT NOT NULL,
  "created_at" TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS "messages_by_id" ON "messages" ("id");
CREATE INDEX IF NOT EXISTS "messages_by_conversation" ON "messages" ("conversation_id", "n");
CREATE INDEX IF NOT EXISTS "messages_by_sender_session" ON "messages" ("sender_session_id", "n");
CREATE INDEX IF NOT EXISTS "messages_by_request" ON "messages" ("request_id", "n");
"""

extension UUID {
  public static func deterministic(_ parts: String...) -> UUID {
    let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    ))
  }
}

public enum ConversationKind: String, Hashable, Sendable, Codable {
  case users
  case box
  case dmUser = "dm_user"
  case dmSession = "dm_session"

  var isOpen: Bool {
    self == .users || self == .box
  }
}

public enum MemberKind: String, Hashable, Sendable, Codable {
  case user
  case session
}

public struct ConversationMember: Hashable, Sendable {
  public var member: String
  public var kind: MemberKind

  public init(member: String, kind: MemberKind) {
    self.member = member
    self.kind = kind
  }
}

public struct ConversationRecord: Hashable, Sendable {
  public var id: ConversationID
  public var kind: ConversationKind
  public var ownerSession: SessionID?
  public var group: GroupID
  public var windowMessages: Int
  public var windowSeconds: Int
  public var members: [ConversationMember]
  public var createdAt: Date
}

public struct MessageRecord: Hashable, Sendable {
  public var n: Int64
  public var id: MessageID
  public var conversation: ConversationID
  public var sender: Sender
  public var senderSession: SessionID?
  /// The group the sender posted from: a session's own, a person's acting
  /// group; for a person's message from before groups, the conversation's.
  public var senderGroup: GroupID
  public var replyTarget: MessageID?
  public var kind: MessageKind
  public var requestID: RequestID?
  public var deadline: Date?
  public var content: MessageContent
  public var createdAt: Date
}

public struct MessageDelivery: Hashable, Sendable {
  public var message: MessageRecord
  public var enqueued: [SessionID]
  public var replayed: Bool
}

public enum ConversationTarget: Hashable, Sendable {
  case conversation(ConversationID)
  case box(SessionID)
  case dm(with: String)
}

public enum ConversationDefaults {
  public static let windowMessages: Int = 10
  public static let windowSeconds: Int = 900
}

enum Conversations {
  static func dmID(_ a: String, _ b: String) -> ConversationID {
    let pair = [a, b].sorted()
    return ConversationID(UUID.deterministic("dm", pair[0], pair[1]).uuidString.lowercased())
  }

  static func record(_ id: String, in db: Database) throws -> ConversationRecord? {
    guard let row = try Row.fetchOne(
      db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id],
    ) else { return nil }
    return ConversationRecord(
      id: ConversationID(row["id"] as String),
      kind: ConversationKind(rawValue: row["kind"])!,
      ownerSession: (row["owner_session"] as String?).map { SessionID($0) },
      group: GroupID(rawValue: row["grp"]),
      windowMessages: Int(row["window_messages"] as Int64),
      windowSeconds: Int(row["window_seconds"] as Int64),
      members: try members(id, in: db),
      createdAt: try SQLiteDateFormat.date(from: row["created_at"]),
    )
  }

  static func members(_ id: String, in db: Database) throws -> [ConversationMember] {
    try Row.fetchAll(
      db,
      sql: "SELECT member, member_kind FROM conversation_members WHERE conversation_id = ? ORDER BY member",
      arguments: [id],
    ).map { ConversationMember(member: $0["member"], kind: MemberKind(rawValue: $0["member_kind"])!) }
  }

  static func create(
    id: String,
    kind: ConversationKind,
    group: GroupID,
    ownerSession: String?,
    members: [ConversationMember],
    now: String,
    in db: Database,
  ) throws {
    try db.execute(
      sql: """
      INSERT OR IGNORE INTO conversations
        (id, kind, owner_session, window_messages, window_seconds, created_at, grp)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      arguments: [
        id, kind.rawValue, ownerSession,
        ConversationDefaults.windowMessages, ConversationDefaults.windowSeconds, now, group.rawValue,
      ],
    )
    for member in members {
      try join(id, member: member, now: now, in: db)
    }
  }

  static func group(of id: String, in db: Database) throws -> GroupID {
    GroupID(rawValue: try String.fetchOne(db, sql: "SELECT grp FROM conversations WHERE id = ?", arguments: [id]) ?? GroupID.shared.rawValue)
  }

  static func join(_ id: String, member: ConversationMember, now: String, in db: Database) throws {
    try db.execute(
      sql: """
      INSERT OR IGNORE INTO conversation_members (conversation_id, member, member_kind, joined_at)
      VALUES (?, ?, ?, ?)
      """,
      arguments: [id, member.member, member.kind.rawValue, now],
    )
  }

  static func memberKind(of principal: String, in db: Database) throws -> MemberKind {
    try Sessions.exists(principal, in: db) ? .session : .user
  }

  // A DM row is minted on first post; the id is a hash of the sorted pair, so
  // two racing posts converge instead of forking the conversation.
  /// `group` homes a DM minted here: the opener's.
  static func resolveDM(_ a: String, _ b: String, group: GroupID, now: String, in db: Database) throws -> ConversationID {
    let id = dmID(a, b)
    if try record(id.rawValue, in: db) == nil {
      let aKind = try memberKind(of: a, in: db)
      let bKind = try memberKind(of: b, in: db)
      try create(
        id: id.rawValue,
        kind: aKind == .session && bKind == .session ? .dmSession : .dmUser,
        group: group,
        ownerSession: nil,
        members: [.init(member: a, kind: aKind), .init(member: b, kind: bKind)],
        now: now,
        in: db,
      )
    }
    return id
  }

  // The device rides in a side table, so the projection every read shares has
  // to carry it: `messages` itself is untouched and old spaces read correctly.
  static let selection = """
  SELECT m.*, (SELECT device_id FROM message_devices WHERE message_id = m.id) AS device_id,
    \(senderGroupSQL) AS sender_grp FROM messages m
  """

  /// A message's sender group, over a `messages` row aliased `m`.
  static let senderGroupSQL = """
  COALESCE((SELECT grp FROM message_groups WHERE message_id = m.id),
    (SELECT grp FROM sessions WHERE id = m.sender_session_id),
    (SELECT grp FROM conversations WHERE id = m.conversation_id))
  """

  static func message(id: String, in db: Database) throws -> MessageRecord? {
    guard let row = try Row.fetchOne(db, sql: "\(selection) WHERE m.id = ?", arguments: [id]) else {
      return nil
    }
    return try decode(row)
  }

  static func decode(_ row: Row) throws -> MessageRecord {
    MessageRecord(
      n: row["n"],
      id: MessageID(row["id"] as String),
      conversation: ConversationID(row["conversation_id"] as String),
      sender: Sender(
        id: row["sender_id"],
        timeZone: TimeZone(identifier: row["sender_timezone"])!,
        device: row["device_id"],
      ),
      senderSession: (row["sender_session_id"] as String?).map { SessionID($0) },
      senderGroup: GroupID(rawValue: (row["sender_grp"] as String?) ?? GroupID.shared.rawValue),
      replyTarget: (row["reply_target"] as String?).map { MessageID($0) },
      kind: MessageKind(rawValue: row["kind"])!,
      requestID: (row["request_id"] as String?).map { RequestID($0) },
      deadline: try (row["deadline_at"] as String?).map(SQLiteDateFormat.date(from:)),
      content: try Sessions.decode(MessageContent.self, from: row["content"]),
      createdAt: try SQLiteDateFormat.date(from: row["created_at"]),
    )
  }

  static func fetch(
    _ db: Database,
    where condition: String,
    arguments: StatementArguments,
    order: String = "n",
    limit: Int? = nil,
  ) throws -> [MessageRecord] {
    var sql = "\(selection) WHERE \(condition) ORDER BY \(order)"
    if let limit { sql += " LIMIT \(limit)" }
    return try Row.fetchAll(db, sql: sql, arguments: arguments).map(decode)
  }
}
