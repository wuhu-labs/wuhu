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
  /// Applies box, DM and channel readership for a session id, persona, or nil (--dev seat).
  public func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID) async throws -> Bool {
    try await writer.read { db in
      try Conversations.reads(conversation, reader: reader, group: group, in: db)
    }
  }

  /// Whether `member` reads `path` in `group` because it is a member of the
  /// conversation homed there whose attachment folder holds it, whatever its
  /// own group reads.
  public func readsAttachment(_ path: String, in group: GroupID, member: String) async throws -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 4, parts[0] == "_", parts[1] == "conversations", parts[3] == "attachments" else { return false }
    return try await writer.read { db in
      guard let record = try Conversations.record(String(parts[2]), in: db) else { return false }
      return record.group == group && record.members.contains { $0.member == member }
    }
  }

  public func attachmentConversation(_ path: String, in group: GroupID) async throws -> ConversationRecord? {
    try await writer.read { db in try fileConversation(path, in: group, db: db) }
  }

  public func readsFile(_ path: String, in group: GroupID, as principal: Principal) async throws -> Bool {
    try await writer.read { db in
      let conversation = try fileConversation(path, in: group, db: db)
      if let conversation, conversation.kind == .users {
        return try Conversations.reads(conversation, reader: principal.member, group: principal.group, in: db)
      }
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

  /// Whether `principal` may write `path` in `group`: a write role there, or
  /// membership of the conversation whose attachments folder holds it (a DM
  /// keeps today's rule).
  public func writesFile(_ path: String, in group: GroupID, as principal: Principal) async throws -> Bool {
    guard try await readsFile(path, in: group, as: principal) else { return false }
    if case .anonymous = principal.actor { return true }
    let held = try await writer.read { db in
      try GroupAccess.role(of: principal.actor, in: group, acting: principal.group, in: db)
    }
    if (held ?? .read) >= .write { return true }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count >= 4, parts[1] == "conversations", parts[3] == "attachments", let member = principal.member else {
      return false
    }
    return try await writer.read { db in
      guard let record = try Conversations.record(String(parts[2]), in: db), record.group == group else { return false }
      return record.members.contains { $0.member == member }
    }
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
    var staged: [(upload: AttachmentUpload, blob: Blob)] = []
    for upload in uploads {
      try await staged.append((upload, blobs.stage(upload.bytes)))
    }
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
    let worker = runtime.worker()
    let cell = ConversationCell.ID(conversation.rawValue)
    if !staged.isEmpty {
      // Attachments are still the group's files, written before the call: a post the cell then refuses leaves them behind.
      let placing = try worker.cell(cell).placing(post)
      if !placing.replayed {
        post.content.attachments += try await Substrate.writeEmitting(writer, to: broadcast) { [staged] db, pending in
          let written = try AttachmentFolder.write(
            staged, conversation: conversation, group: placing.group, at: now, mtime: SQLiteDateFormat.string(from: now), in: db,
          )
          pending += written.attachments.map {
            MutationEvent(group: placing.group, path: $0.path, rev: Int(written.rev), kind: .write, entry: .file)
          }
          return written.attachments
        }
      }
    }
    return try await worker.call(cell) { [post] in try $0.post(post) }
  }

  public func message(_ id: MessageID) async throws -> MessageRecord? {
    try await writer.read { db in try Conversations.message(id: id.rawValue, in: db) }
  }
}

extension Conversations {
  static func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID, in db: Database) throws -> Bool {
    try conversation.reads(reader, isSession: try reader.map { try Sessions.exists($0, in: db) } ?? false, group: group) {
      try reach(reader: reader, group: group, in: db)
    }
  }

  /// The groups a reader reaches: a session's own group's reach, a persona's
  /// account and acting group.
  private static func reach(reader: String?, group: GroupID, in db: Database) throws -> Set<GroupID> {
    guard let reader, try !Sessions.exists(reader, in: db) else {
      return try GroupAccess.reach(of: group, in: db)
    }
    guard let account = try String.fetchOne(
      db, sql: "SELECT account_id FROM personas WHERE name = ?", arguments: [reader],
    ) else { return try GroupAccess.reach(of: group, in: db) }
    return try GroupAccess.readable(
      by: .person(persona: reader, account: AccountID(rawValue: account)), acting: group, in: db,
    )
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

private func fileConversation(_ path: String, in group: GroupID, db: Database) throws -> ConversationRecord? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: true)
  guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations",
        let record = try Conversations.record(String(parts[2]), in: db), record.group == group else { return nil }
  return record
}
