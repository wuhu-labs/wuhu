#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

/// A message on its way into a conversation, as its poster calls the conversation's cell with it.
struct Post: Sendable {
  /// How the poster named the conversation whose cell this reaches. A DM that was never opened is made by its first post, so that one names the other member.
  enum Target: Sendable {
    case conversation
    case box
    case dm(with: String)
  }

  var target: Target
  var messageID: MessageID
  var sender: Sender
  var senderSession: SessionID?
  var kind: MessageKind = .message
  var requestID: RequestID?
  var replyTarget: MessageID?
  var viewing: Viewing?
  var content: MessageContent
  var uploads: [Upload] = []
  var acting: Principal?
  var request: RequestStep?
  var at: Date
}

extension Post {
  /// An upload whose bytes are stored: what the conversation needs to place it. `file` names it by its upload name until then.
  struct Upload: Sendable {
    var name: String
    var blob: String
    var size: Int
    var file: Attachment
  }
}

/// What a post does to the request it belongs to, in the step that writes its message.
enum RequestStep: Sendable {
  case open(requester: Caller, task: SessionID, brief: String, terms: RequestTerms, stallSeconds: Double?)
  /// The task was heard from: the requester's quiet reminder moves.
  case progress
  case close(as: RequestStatus, result: String?)
}

/// A conversation's live tail: the messages past `after`, then each one as it is posted. `viewer` is who reads at the other end, nil for one who reads everything; the cell closes the socket instead of sending to a viewer who no longer reads the conversation.
enum ConversationTail: Socket {
  struct Opening: Sendable {
    var after: Int64
    var viewer: Principal?
  }

  typealias Outgoing = [MessageRecord]
}

/// A conversation (a box, a DM, a channel), keyed by its id. A post is a call: one step checks the poster's reach, writes the message and what its request needs, and mails each recipient: a session its input, a person their notice.
@Cell
struct ConversationCell {
  static let owned = ["conversations": "id", "conversation_members": "conversation_id", "conversation_titles": "conversation_id", "messages": "conversation_id", "requests": "conversation_id", "attachments": "conversation_id"]

  /// A box is there from its session's creation, and written by its first post.
  func record() -> ConversationRecord? {
    guard let row = db.rows(ConversationRow.where { $0.id.eq(id.key) }).first else { return unopenedBox() }
    let kind = ConversationKind(rawValue: row.kind)!
    return ConversationRecord(
      id: ConversationID(row.id),
      kind: kind,
      ownerSession: row.ownerSession.map { SessionID($0) },
      title: db.rows(ConversationTitleRow.where { $0.conversationID.eq(id.key) }).first?.title,
      group: GroupID(rawValue: row.group),
      windowMessages: row.windowMessages,
      windowSeconds: row.windowSeconds,
      members: db.rows(ConversationMemberRow.where { $0.conversationID.eq(id.key) }.order { $0.member })
        .map { ConversationMember(member: $0.member, kind: MemberKind(rawValue: $0.kind)!) }
        .filter { kind != .users || $0.kind == .user },
      createdAt: try! SQLiteDateFormat.date(from: row.createdAt),
    )
  }

  /// A message of this conversation.
  func message(_ message: MessageID) -> MessageRecord? {
    db.rows("\(Conversations.selection) WHERE m.id = ? AND m.conversation_id = ?", .text(message.rawValue), .text(id.key)).first.map(MessageRecord.init(row:))
  }

  mutating func attached(_ socket: SocketHandle<ConversationTail>) {
    guard let record = record(), reads(record, as: socket.opening.viewer) else { return socket.close() }
    let missed = messages(where: "m.n > ?", .integer(socket.opening.after), limit: nil)
    if !missed.isEmpty { socket.send(missed) }
  }

  mutating func post(_ post: Post) throws -> MessageDelivery {
    if case let .open(requester, task, _, _, _)? = post.request, let id = post.requestID { try mayOpen(id, on: task, from: requester) }
    let poster = poster(of: post)
    let conversation = try admit(post, poster: poster)
    guard conversation.kind != .dmUser || (post.senderSession == nil && !conversation.members.contains(where: { $0.kind == .session })) else {
      throw SessionStoreError.humanAgentDirectMessage
    }
    if let existing = message(post.messageID) {
      return MessageDelivery(message: existing, enqueued: [], replayed: true)
    }
    if let replyTarget = post.replyTarget, message(replyTarget) == nil {
      throw db.one("SELECT 1 FROM messages WHERE id = ?", .text(replyTarget.rawValue)) == nil
        ? SessionStoreError.unknownMessage(replyTarget.rawValue)
        : SessionStoreError.replyTargetInAnotherConversation(replyTarget.rawValue)
    }
    let now = SQLiteDateFormat.string(from: post.at)
    if !isWritten { try make(conversation, now: now) }
    if conversation.kind == .box {
      try join(ConversationMember(member: post.senderSession?.rawValue ?? post.sender.id, kind: post.senderSession == nil ? .user : .session), now: now)
    }
    var content = post.content
    content.attachments += try attach(post.uploads, at: post.at)
    try db.execute(
      """
      INSERT INTO messages
        (id, conversation_id, sender_id, sender_session_id, sender_timezone,
         reply_target, kind, request_id, content, created_at, firing)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      .text(post.messageID.rawValue), .text(id.key), .text(post.sender.id), text(post.senderSession?.rawValue),
      .text(post.sender.timeZone.identifier), text(post.replyTarget?.rawValue), .text(post.kind.rawValue), text(post.requestID?.rawValue),
      .text(try Sessions.encode(content)), .text(now), text(poster.firing),
    )
    if let device = post.sender.device {
      try db.execute("INSERT OR IGNORE INTO message_devices (message_id, device_id) VALUES (?, ?)", .text(post.messageID.rawValue), .text(device))
    }
    if let viewing = post.viewing {
      try db.execute("INSERT INTO message_viewing (message_id, path) VALUES (?, ?)", .text(post.messageID.rawValue), .text(viewing.stored))
    }
    try db.execute("INSERT OR IGNORE INTO message_groups (message_id, grp) VALUES (?, ?)", .text(post.messageID.rawValue), .text(poster.group.rawValue))
    let record = message(post.messageID)!
    if let request = post.request, let id = post.requestID {
      try step(request, of: id, at: record.createdAt)
    }
    for socket in ctx.sockets(of: ConversationTail.self) {
      if reads(conversation, as: socket.opening.viewer) { socket.send([record]) } else { socket.close() }
    }
    return MessageDelivery(message: record, enqueued: try deliver(record, conversation: conversation, poster: poster, at: post.at), replayed: false)
  }
}

private func text(_ value: String?) -> Value {
  value.map { .text($0) } ?? .null
}

extension MessageRecord {
  /// A row of `Conversations.selection`.
  init(row: Row) {
    self.init(
      n: row["n"].integer!,
      id: MessageID(row["id"].text!),
      conversation: ConversationID(row["conversation_id"].text!),
      sender: Sender(id: row["sender_id"].text!, timeZone: TimeZone(identifier: row["sender_timezone"].text!)!, device: row["device_id"].text),
      senderSession: row["sender_session_id"].text.map { SessionID($0) },
      senderGroup: GroupID(rawValue: row["sender_grp"].text ?? GroupID.shared.rawValue),
      replyTarget: row["reply_target"].text.map { MessageID($0) },
      kind: MessageKind(rawValue: row["kind"].text!)!,
      requestID: row["request_id"].text.map { RequestID($0) },
      viewing: row["viewing"].text.map(Viewing.stored),
      content: try! Sessions.decode(MessageContent.self, from: row["content"].text!),
      createdAt: try! SQLiteDateFormat.date(from: row["created_at"].text!),
    )
  }
}
