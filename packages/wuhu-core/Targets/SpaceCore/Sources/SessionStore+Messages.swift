import Dependencies
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
  public func conversation(_ id: ConversationID) async throws -> ConversationRecord {
    try await writer.read { db in
      guard let record = try Conversations.record(id.rawValue, in: db) else {
        throw SessionStoreError.unknownConversation(id.rawValue)
      }
      return record
    }
  }

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
        case .session, .observer, .anonymous: guard principal.group == group else { return false }
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

  /// `group` homes it: the group its opener acts in.
  @discardableResult
  public func createConversation(members: [String], title: String? = nil, in group: GroupID) async throws -> ConversationID {
    @Dependency(\.uuid) var uuid
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let id = ConversationID(uuid().uuidString.lowercased())
    try await writer.write { db in
      let members = try Channels.resolve(members, in: db)
      try Channels.validate(title: title)
      try Conversations.create(
        id: id.rawValue,
        kind: .users,
        group: group,
        ownerSession: nil,
        members: try members.map { .init(member: $0, kind: try Conversations.memberKind(of: $0, in: db)) },
        now: now,
        in: db,
      )
      try ConversationTitleRow.upsert { ConversationTitleRow(conversationID: id.rawValue, title: title) }.execute(db)
    }
    return id
  }

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
    alongside: (@Sendable (MessageRecord, Database) throws -> Void)? = nil,
  ) async throws -> MessageDelivery {
    // `alongside` commits with a new message and never runs for a replayed
    // one: what it writes (a request's clocks) exists exactly when the
    // message does.
    precondition(viewing == nil || senderSession == nil, "only a person's message carries viewing")
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    var staged: [(upload: AttachmentUpload, blob: Blob)] = []
    for upload in uploads {
      try await staged.append((upload, blobs.stage(upload.bytes)))
    }
    let broadcast = broadcast
    let delivery = try await Substrate.writeEmitting(writer, to: broadcast) { [staged] db, pending in
      let existing = try Conversations.message(id: messageID.rawValue, in: db)
      let poster = Poster(
        actor: senderSession.map(Actor.session) ?? acting?.actor,
        persona: sender.id,
        group: try senderSession.map { try Sessions.group(of: $0.rawValue, in: db) } ?? acting?.group ?? .shared,
      )
      let conversation = try resolve(existing.map { .conversation($0.conversation) } ?? target, sender: sender, senderSession: senderSession, poster: poster, now: now, in: db)
      guard conversation.kind != .dmUser || (senderSession == nil && !conversation.members.contains(where: { $0.kind == .session })) else {
        throw SessionStoreError.humanAgentDirectMessage
      }
      if let existing {
        return MessageDelivery(message: existing, enqueued: [], replayed: true)
      }
      if let replyTarget {
        guard let parent = try Conversations.message(id: replyTarget.rawValue, in: db) else {
          throw SessionStoreError.unknownMessage(replyTarget.rawValue)
        }
        guard parent.conversation == conversation.id else {
          throw SessionStoreError.replyTargetInAnotherConversation(replyTarget.rawValue)
        }
      }
      if conversation.kind == .box {
        try Conversations.join(
          conversation.id.rawValue,
          member: .init(
            member: senderSession?.rawValue ?? sender.id,
            kind: senderSession == nil ? .user : .session,
          ),
          now: now,
          in: db,
        )
      }
      var content = content
      let written = try staged.isEmpty ? nil : AttachmentFolder.write(
        staged, conversation: conversation.id, group: conversation.group, at: nowDate, mtime: now, in: db,
      )
      content.attachments += written?.attachments ?? []
      try db.execute(
        sql: """
        INSERT INTO messages
          (id, conversation_id, sender_id, sender_session_id, sender_timezone,
           reply_target, kind, request_id, content, created_at, firing)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
          messageID.rawValue, conversation.id.rawValue, sender.id, senderSession?.rawValue,
          sender.timeZone.identifier, replyTarget?.rawValue, kind.rawValue, requestID?.rawValue,
          try Sessions.encode(content), now, poster.firing,
        ],
      )
      if let device = sender.device {
        try db.execute(
          sql: "INSERT OR IGNORE INTO message_devices (message_id, device_id) VALUES (?, ?)",
          arguments: [messageID.rawValue, device],
        )
      }
      if let viewing {
        try Viewing.insert(viewing, message: messageID.rawValue, in: db)
      }
      try db.execute(
        sql: "INSERT OR IGNORE INTO message_groups (message_id, grp) VALUES (?, ?)",
        arguments: [messageID.rawValue, poster.group.rawValue],
      )
      // Read again after `alongside`: a request's deadline lives on its row.
      try alongside?(Conversations.message(id: messageID.rawValue, in: db)!, db)
      let record = try Conversations.message(id: messageID.rawValue, in: db)!
      let enqueued = try deliver(record, conversation: conversation, poster: poster, nowDate: nowDate, now: now, in: db)
      if let written {
        pending += written.attachments.map {
          MutationEvent(group: conversation.group, path: $0.path, rev: Int(written.rev), kind: .write, entry: .file)
        }
      }
      return MessageDelivery(message: record, enqueued: enqueued, replayed: false)
    }
    for recipient in delivery.enqueued {
      signals.post(recipient)
    }
    return delivery
  }

  public func message(_ id: MessageID) async throws -> MessageRecord? {
    try await writer.read { db in try Conversations.message(id: id.rawValue, in: db) }
  }

  public func messages(
    conversation: ConversationID,
    after n: Int64 = 0,
    limit: Int? = nil,
  ) async throws -> [MessageRecord] {
    let key = conversation.rawValue
    return try await writer.read { db in
      guard try Conversations.record(key, in: db) != nil else {
        throw SessionStoreError.unknownConversation(key)
      }
      return try Conversations.fetch(db, where: "conversation_id = ? AND n > ?", arguments: [key, n], limit: limit)
    }
  }

  public func messagesTail(
    conversation: ConversationID,
    before n: Int64? = nil,
    limit: Int,
  ) async throws -> [MessageRecord] {
    let key = conversation.rawValue
    return try await writer.read { db in
      guard try Conversations.record(key, in: db) != nil else {
        throw SessionStoreError.unknownConversation(key)
      }
      let page: [MessageRecord] = if let n {
        try Conversations.fetch(
          db, where: "conversation_id = ? AND n < ?", arguments: [key, n], order: "n DESC", limit: limit,
        )
      } else {
        try Conversations.fetch(db, where: "conversation_id = ?", arguments: [key], order: "n DESC", limit: limit)
      }
      return page.reversed()
    }
  }
}

struct Poster {
  var actor: Actor?
  var persona: String
  var group: GroupID

  var firing: String? {
    if case let .observer(observer)? = actor { observer.firing } else { nil }
  }

  func isAdmin(of group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case .anonymous:
      return true
    case let actor?:
      return try GroupAccess.role(of: actor, in: group, acting: self.group, in: db) == .admin
    case nil:
      guard let account = try personaAccount(in: db) else { return false }
      return try GroupAccess.isHumanAdmin(account, of: group, in: db)
    }
  }

  /// The groups this poster reads: its account's entries and its acting group's
  /// reach.
  func readable(in db: Database) throws -> Set<GroupID> {
    switch actor {
    case .anonymous:
      return try GroupAccess.reach(of: group, in: db)
    case let actor?:
      return try GroupAccess.readable(by: actor, acting: group, in: db)
    case nil:
      guard let account = try personaAccount(in: db) else { return try GroupAccess.reach(of: group, in: db) }
      return try GroupAccess.readable(by: .person(persona: persona, account: account), acting: group, in: db)
    }
  }

  private func personaAccount(in db: Database) throws -> AccountID? {
    try String.fetchOne(db, sql: "SELECT account_id FROM personas WHERE name = ?", arguments: [persona])
      .map(AccountID.init(rawValue:))
  }
}

extension SessionStore {
  // A conversation is there for a poster whose group reads its group, or who
  // is a member; anything else is refused as missing. No dialing in: a DM to
  // a session outside what the poster's group reads is opened or used only
  // when that session has posted in it.
  private func resolve(
    _ target: ConversationTarget,
    sender: Sender,
    senderSession: SessionID?,
    poster: Poster,
    now: String,
    in db: Database,
  ) throws -> ConversationRecord {
    let me = senderSession?.rawValue ?? sender.id
    let readable = try poster.readable(in: db)
    switch target {
    case let .conversation(id):
      guard let record = try Conversations.record(id.rawValue, in: db),
            readable.contains(record.group) || record.members.contains(where: { $0.member == me })
      else {
        throw SessionStoreError.unknownConversation(id.rawValue)
      }
      if record.kind == .users && senderSession == nil && !record.members.contains(where: { $0.member == me && $0.kind == .user }) {
        throw SessionStoreError.unknownConversation(id.rawValue)
      }
      if record.kind == .dmUser || record.kind == .dmSession {
        for other in record.members where other.kind == .session && other.member != me {
          guard try reaches(other.member, from: readable, in: record, in: db) else {
            throw SessionStoreError.unknownConversation(id.rawValue)
          }
        }
      }
      return record
    case let .box(owner):
      guard try Sessions.exists(owner.rawValue, in: db),
            readable.contains(try Sessions.group(of: owner.rawValue, in: db))
      else { throw SessionStoreError.unknownSession(owner.rawValue) }
      guard try Sessions.record(owner.rawValue, in: db).kind == .agent else {
        throw senderSession == nil
          ? SessionStoreError.taskTakesNoHumanInput(owner.rawValue)
          : SessionStoreError.taskHasNoBox(owner.rawValue)
      }
      guard let conversation = try Conversations.record(owner.rawValue, in: db) else {
        throw SessionStoreError.unknownConversation(owner.rawValue)
      }
      return conversation
    case let .dm(spelling):
      let other: String
      if try Sessions.exists(spelling, in: db) {
        other = spelling
      } else {
        guard let person = try Aliases.resolvePerson(spelling, in: db) else {
          throw SessionStoreError.unknownPerson(spelling)
        }
        other = person
      }
      guard me != other else { throw SessionStoreError.selfDirectMessage(me) }
      if try Sessions.exists(other, in: db) {
        let existing = try Conversations.record(Conversations.dmID(me, other).rawValue, in: db)
        let reached = if let existing {
          try reaches(other, from: readable, in: existing, in: db)
        } else {
          readable.contains(try Sessions.group(of: other, in: db))
        }
        guard reached else { throw SessionStoreError.unknownSession(other) }
      } else if try Conversations.memberKind(of: other, in: db) == .session {
        throw SessionStoreError.unknownSession(other)
      }
      let id = try Conversations.resolveDM(me, other, group: poster.group, now: now, in: db)
      return try Conversations.record(id.rawValue, in: db)!
    }
  }

  // Whether a post from a group reading `readable` may reach session `key` in
  // `conversation`: its group is readable, it owns the conversation, or it
  // has posted there.
  private func reaches(
    _ key: String, from readable: Set<GroupID>, in conversation: ConversationRecord, in db: Database,
  ) throws -> Bool {
    if conversation.ownerSession?.rawValue == key { return true }
    if readable.contains(try Sessions.group(of: key, in: db)) { return true }
    return try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM messages WHERE conversation_id = ? AND sender_session_id = ?)",
      arguments: [conversation.id.rawValue, key],
    ) ?? false
  }

  private func deliver(
    _ message: MessageRecord,
    conversation: ConversationRecord,
    poster: Poster,
    nowDate: Date,
    now: String,
    in db: Database,
  ) throws -> [SessionID] {
    let routingDate = try SQLiteDateFormat.date(from: now)
    let snapshot = try routingSnapshot(message, conversation: conversation, poster: poster, in: db)
    let routed = try recipients(snapshot: snapshot, message: message, now: routingDate)

    var enqueued: [SessionID] = []
    for key in routed.woken {
      let recipient = key.rawValue
      let owes = message.kind == .message && snapshot.sessions[key]?.kind == .agent && conversation.ownerSession == key
      let home = try Sessions.group(of: recipient, in: db)
      let input = QueueInput.message(ConversationMessage(
        id: .deterministic("deliver", message.id.rawValue, recipient),
        messageID: message.id,
        conversationID: conversation.id,
        sender: message.sender,
        senderSession: message.senderSession,
        timestamp: message.createdAt,
        kind: message.kind,
        requestID: message.requestID,
        deadline: message.deadline,
        replyTarget: message.replyTarget,
        owesReply: owes,
        senderGroup: poster.group == home ? nil : poster.group,
        senderAdmin: try poster.isAdmin(of: home, in: db),
        viewing: message.viewing?.named(for: home),
        content: message.content.attachments(in: conversation.group, for: home),
      ))
      do {
        _ = try Sessions.enqueue(recipient, input: input, nowDate: nowDate, in: db)
        enqueued.append(SessionID(recipient))
      } catch SessionStoreError.archiveGraceExpired {} catch SessionStoreError.unknownSession {}
    }

    let group = try Conversations.group(of: conversation.id.rawValue, in: db)
    for member in routed.notified {
      try Notifications.append(
        recipient: member,
        source: conversation.id.rawValue,
        group: group,
        kind: .conversationMessage,
        payload: Notifications.conversationPayload(
          messageID: message.id, conversation: conversation.id,
          sender: message.sender.id, senderGroup: poster.group == group ? nil : poster.group,
          text: message.content.text,
        ),
        now: now,
        in: db,
      )
    }
    return enqueued
  }

  private func routingSnapshot(
    _ message: MessageRecord, conversation: ConversationRecord, poster: Poster, in db: Database,
  ) throws -> RoutingSnapshot {
    let audience: RoutingSnapshot.Audience
    switch conversation.kind {
    case .box:
      guard let owner = conversation.ownerSession else { throw SessionStoreError.unknownConversation(conversation.id.rawValue) }
      audience = .box(owner, messages: conversation.windowMessages, seconds: conversation.windowSeconds)
    case .users:
      audience = .channel(messages: conversation.windowMessages, seconds: conversation.windowSeconds)
    case .dmUser, .dmSession:
      audience = .direct(conversation.members.filter { $0.kind == .session }.map { SessionID($0.member) })
    }
    let replySender: RoutingSnapshot.ReplySender
    if let reply = message.replyTarget,
       let parent = try Conversations.message(id: reply.rawValue, in: db)?.senderSession
    {
      replySender = .session(parent)
    } else {
      replySender = .unaddressed
    }
    let conversationID = conversation.id.rawValue
    let before = message.n
    let tail = try #sql("""
    SELECT sender_session_id, created_at FROM messages
    WHERE \(conversation.kind.isOpen) AND conversation_id = \(bind: conversationID) AND n < \(bind: before)
    ORDER BY n DESC LIMIT \(bind: max(0, conversation.windowMessages))
    """, as: RoutingMessage.self).fetchAll(db)
    var seen: Set<String> = []
    let recent = try tail.enumerated().compactMap { index, row -> RoutingSnapshot.RecentSender? in
      guard let session = row.session, seen.insert(session).inserted else { return nil }
      return (SessionID(session), try SQLiteDateFormat.date(from: row.createdAt), index)
    }.sorted { $0.session.rawValue < $1.session.rawValue }
    var candidates = MentionScanner.candidates(in: message.content.text)
    candidates += conversation.members.filter { $0.kind == .session }.map(\.member)
    candidates += recent.map { $0.session.rawValue }
    if let owner = conversation.ownerSession { candidates.append(owner.rawValue) }
    if case let .session(parent) = replySender { candidates.append(parent.rawValue) }
    let readable = try poster.readable(in: db)
    let sessions = try RoutingSessionRow.where { $0.id.in(candidates) }.fetchAll(db).map { row in
      (SessionID(row.id), (
        kind: row.kind,
        reachable: try reaches(row.id, from: readable, in: conversation, in: db),
      ))
    }
    return RoutingSnapshot(
      audience: audience, people: conversation.members.filter { $0.kind == .user }.map(\.member),
      sessions: Dictionary(uniqueKeysWithValues: sessions), replySender: replySender, recentSenders: recent,
    )
  }
}

extension Conversations {
  static func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID, in db: Database) throws -> Bool {
    let session = try reader.map { try Sessions.exists($0, in: db) } ?? false
    if conversation.ownerSession != nil || (conversation.kind == .users && session) {
      return try reach(reader: reader, group: group, in: db).contains(conversation.group)
    }
    guard let reader else { return conversation.kind != .users && conversation.group == group }
    if conversation.members.contains(where: { $0.member == reader && (conversation.kind != .users || $0.kind == .user) }) { return true }
    return conversation.kind != .users && conversation.group == group
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

private func fileConversation(_ path: String, in group: GroupID, db: Database) throws -> ConversationRecord? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: true)
  guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations",
        let record = try Conversations.record(String(parts[2]), in: db), record.group == group else { return nil }
  return record
}

@Table("sessions")
private struct RoutingSessionRow {
  var id: String
  var kind: SessionKind
}

@Selection
private struct RoutingMessage {
  var session: String?
  var createdAt: String
}

extension SessionKind: QueryBindable {}
