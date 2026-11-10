#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

extension SessionStore {
  /// Whether `member` reads `path` in `group` because it is a member of the conversation homed there whose attachment folder holds it, whatever its own group reads.
  public func readsAttachment(_ path: String, in group: GroupID, member: String) async throws -> Bool {
    try await attachmentConversation(path, in: group)?.members.contains { $0.member == member } == true
  }

  /// The conversation homed in `group` whose folder holds `path`.
  public func attachmentConversation(_ path: String, in group: GroupID) async throws -> ConversationRecord? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations",
          let record = runtime.worker().cell(ConversationCell.ID(String(parts[2]))).record(), record.group == group else { return nil }
    return record
  }

  public func readsFile(_ path: String, in group: GroupID, as principal: Principal) async throws -> Bool {
    let conversation = try await attachmentConversation(path, in: group)
    if let conversation, conversation.kind == .users {
      return try await reads(conversation, reader: principal.member, group: principal.group)
    }
    return try await writer.read { db in
      // A person's own group is theirs alone: it reads as nothing to everyone
      // else, including a space admin.
      if let owner = try String.fetchOne(
        db, sql: "SELECT personal_account FROM groups WHERE id = ? AND personal_account IS NOT NULL",
        arguments: [group.rawValue],
      ) {
        switch principal.actor {
        case let .person(_, account): guard account.rawValue == owner else { return false }
        case .session, .observer, .page, .anonymous: guard principal.group == group else { return false }
        }
      }
      if group == principal.group { return true }
      if try GroupAccess.readable(by: principal.actor, acting: principal.group, in: db).contains(group) { return true }
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      guard parts.count >= 4, parts[3] == "attachments", let member = principal.member else { return false }
      return conversation?.members.contains { $0.member == member } == true
    }
  }

  /// Whether `principal` may write `path` in `group`: it reads it and holds a write role there.
  public func writesFile(_ path: String, in group: GroupID, as principal: Principal) async throws -> Bool {
    guard try await readsFile(path, in: group, as: principal) else { return false }
    if case .anonymous = principal.actor { return true }
    let held = try await writer.read { db in
      try GroupAccess.role(of: principal.actor, in: group, acting: principal.group, in: db)
    }
    return (held ?? .read) >= .write
  }

  public func conversations(member: String) async throws -> [ConversationRecord] {
    try await writer.read { db in
      try String.fetchAll(
        db,
        sql: """
        SELECT c.id FROM conversations c
        JOIN conversation_members m ON m.conversation_id = c.id
        WHERE m.member = ?
        ORDER BY COALESCE((SELECT MAX(n) FROM messages WHERE conversation_id = c.id), 0) DESC
        """,
        arguments: [member],
      ).compactMap { try Conversations.record($0, in: db) }
    }
  }

  public func conversations(reader: String?, group: GroupID) async throws -> [ConversationRecord] {
    let records = try await writer.read { db in
      try ConversationRow.order {
        #sql("COALESCE((SELECT MAX(n) FROM messages WHERE conversation_id = \($0.id)), 0)", as: Int64.self).desc()
      }.fetchAll(db).compactMap { try Conversations.record($0.id, in: db) }
    }
    var readable: [ConversationRecord] = []
    for record in records {
      if record.kind == .users {
        if try await reads(record, reader: reader, group: group) { readable.append(record) }
      } else if record.members.contains(where: { $0.member == reader }) { readable.append(record) }
    }
    return readable
  }

  /// A post is a call to its conversation's cell.
  public func post(
    _ target: ConversationTarget,
    messageID: MessageID,
    sender: Sender,
    senderSession: SessionID? = nil,
    kind: MessageKind = .message,
    requestID: RequestID? = nil,
    replyTarget: MessageID? = nil,
    viewing: Viewing? = nil,
    content: MessageContent,
    uploads: [AttachmentUpload] = [],
    acting: Principal? = nil,
  ) async throws -> MessageDelivery {
    precondition(viewing == nil || senderSession == nil, "only a person's message carries viewing")
    let now = dateGen.now
    let me = senderSession?.rawValue ?? sender.id
    // Still main's reads: which conversation holds a message posted before, and who a DM's spelling names.
    let (conversation, place): (ConversationID, Post.Target) = try await writer.read { db in
      if let existing = try Conversations.message(id: messageID.rawValue, in: db) { return (existing.conversation, .conversation) }
      switch target {
      case let .conversation(id):
        return (id, .conversation)
      case let .box(owner):
        return (ConversationID(owner.rawValue), .box)
      case let .dm(spelling):
        let other: String
        if try Sessions.exists(spelling, in: db) {
          other = spelling
        } else {
          guard let person = try Aliases.resolvePerson(spelling, in: db) else { throw SessionStoreError.unknownPerson(spelling) }
          other = person
        }
        guard me != other else { throw SessionStoreError.selfDirectMessage(me) }
        return (Conversations.dmID(me, other), .dm(with: other))
      }
    }
    var post = Post(
      target: place, messageID: messageID, sender: sender, senderSession: senderSession, kind: kind, requestID: requestID, replyTarget: replyTarget,
      viewing: viewing, content: content, acting: acting, at: now,
    )
    // The bytes are stored before the call, by their hash: a post the cell then refuses leaves a blob nothing names.
    var staged: [Blob] = []
    for upload in uploads {
      let blob = try await blobs.stage(upload.bytes)
      staged.append(blob)
      post.uploads.append(Post.Upload(name: upload.name, blob: blob.hash, size: upload.bytes.count, file: upload.attachment(at: upload.name)))
    }
    if !staged.isEmpty {
      try await writer.write { [staged] db in
        for blob in staged { try Substrate.record(blob, in: db) }
      }
    }
    let worker = runtime.worker()
    let cell = ConversationCell.ID(conversation.rawValue)
    return try await worker.call(cell) { [post] in try $0.post(post) }
  }

  public func message(_ id: MessageID) async throws -> MessageRecord? {
    try await writer.read { db in try Conversations.message(id: id.rawValue, in: db) }
  }
}

extension ConversationRecord {
  /// Box, DM and channel readership for a session id, a persona, or nil (the --dev seat) acting in `group`. `reach` is the groups that reader reads.
  func reads(_ reader: String?, isSession: Bool, group: GroupID, reach: () throws -> Set<GroupID>) rethrows -> Bool {
    if ownerSession != nil || (kind == .users && isSession) { return try reach().contains(self.group) }
    guard let reader else { return kind != .users && self.group == group }
    if members.contains(where: { $0.member == reader && (kind != .users || $0.kind == .user) }) { return true }
    return kind != .users && self.group == group
  }
}
