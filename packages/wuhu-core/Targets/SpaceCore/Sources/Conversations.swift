import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite
import Wuwei
import WuweiQueries

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
  public var title: String?
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
  public var viewing: Viewing?
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
    guard let row = db.rows(ConversationRow.where({ $0.id.eq(id) })).first else { return nil }
    return ConversationRecord(
      id: ConversationID(row.id),
      kind: ConversationKind(rawValue: row.kind)!,
      ownerSession: row.ownerSession.map { SessionID($0) },
      title: db.rows(ConversationTitleRow.where { $0.conversationID.eq(id) }).first?.title,
      group: GroupID(rawValue: row.group),
      windowMessages: row.windowMessages,
      windowSeconds: row.windowSeconds,
      members: try members(id, in: db).filter { row.kind != ConversationKind.users.rawValue || $0.kind == .user },
      createdAt: try SQLiteDateFormat.date(from: row.createdAt),
    )
  }

  static func members(_ id: String, in db: Database) throws -> [ConversationMember] {
    db.rows(ConversationMemberRow.where { $0.conversationID.eq(id) }.order { $0.member })
      .map { ConversationMember(member: $0.member, kind: MemberKind(rawValue: $0.kind)!) }
  }

  // The device and the viewed page ride in side tables, so the projection every
  // read shares has to carry them: `messages` itself is untouched and old
  // spaces read correctly.
  static let selection = """
  SELECT m.*, (SELECT device_id FROM message_devices WHERE message_id = m.id) AS device_id,
    (SELECT path FROM message_viewing WHERE message_id = m.id) AS viewing,
    \(senderGroupSQL) AS sender_grp FROM messages m
  """

  /// A message's sender group, over a `messages` row aliased `m`.
  static let senderGroupSQL = """
  COALESCE((SELECT grp FROM message_groups WHERE message_id = m.id),
    (SELECT grp FROM sessions WHERE id = m.sender_session_id),
    (SELECT grp FROM conversations WHERE id = m.conversation_id))
  """

  static func message(id: String, in db: Database) -> MessageRecord? {
    db.rows("\(selection) WHERE m.id = ?", .text(id)).first.map(MessageRecord.init(row:))
  }

  static func fetch(_ db: Database, where condition: String, arguments: [Value], order: String = "n", limit: Int? = nil) -> [MessageRecord] {
    var sql = "\(selection) WHERE \(condition) ORDER BY \(order)"
    if let limit { sql += " LIMIT \(limit)" }
    return db.rows(sql, arguments).map(MessageRecord.init(row:))
  }
}

@Table("conversations")
struct ConversationRow {
  @Column(primaryKey: true) var id: String
  var kind: String
  @Column("owner_session") var ownerSession: String?
  @Column("window_messages") var windowMessages: Int
  @Column("window_seconds") var windowSeconds: Int
  @Column("created_at") var createdAt: String
  @Column("grp") var group: String
}

@Table("conversation_members")
struct ConversationMemberRow {
  @Column("conversation_id") var conversationID: String
  var member: String
  @Column("member_kind") var kind: String
  @Column("joined_at") var joinedAt: String
}

@Table("conversation_titles")
struct ConversationTitleRow {
  @Column("conversation_id", primaryKey: true) var conversationID: String
  var title: String?
}
