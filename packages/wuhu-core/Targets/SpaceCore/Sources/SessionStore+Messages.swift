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
      if group == principal.group { return true }
      if try Groups.reads(principal.group, in: db).contains(group) { return true }
      let parts = path.split(separator: "/", omittingEmptySubsequences: true)
      guard parts.count >= 4, parts[3] == "attachments", let member = principal.member else { return false }
      return conversation?.members.contains { $0.member == member } == true
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
      try Channels.validate(members, in: db)
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
    deadline: Date? = nil,
    replyTarget: MessageID? = nil,
    content: MessageContent,
    uploads: [AttachmentUpload] = [],
    acting: Principal? = nil,
  ) async throws -> MessageDelivery {
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    var staged: [(upload: AttachmentUpload, blob: Blob)] = []
    for upload in uploads {
      try await staged.append((upload, blobs.stage(upload.bytes)))
    }
    let (delivery, written) = try await writer.write { [staged] db in
      let existing = try Conversations.message(id: messageID.rawValue, in: db)
      // A session posts from its own group, a person from the one it acts in.
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
        return (MessageDelivery(message: existing, enqueued: [], replayed: true), nil as (group: GroupID, rev: Int64, attachments: [Attachment])?)
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
           reply_target, kind, request_id, deadline_at, content, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
          messageID.rawValue, conversation.id.rawValue, sender.id, senderSession?.rawValue,
          sender.timeZone.identifier, replyTarget?.rawValue, kind.rawValue, requestID?.rawValue,
          deadline.map(SQLiteDateFormat.string(from:)), try Sessions.encode(content), now,
        ],
      )
      if let device = sender.device {
        try db.execute(
          sql: "INSERT OR IGNORE INTO message_devices (message_id, device_id) VALUES (?, ?)",
          arguments: [messageID.rawValue, device],
        )
      }
      try db.execute(
        sql: "INSERT OR IGNORE INTO message_groups (message_id, grp) VALUES (?, ?)",
        arguments: [messageID.rawValue, poster.group.rawValue],
      )
      let record = try Conversations.message(id: messageID.rawValue, in: db)!
      let enqueued = try deliver(record, conversation: conversation, poster: poster, nowDate: nowDate, now: now, in: db)
      return (MessageDelivery(message: record, enqueued: enqueued, replayed: false), written.map { (conversation.group, $0.rev, $0.attachments) })
    }
    if let written {
      for attachment in written.attachments {
        broadcast.emit(MutationEvent(group: written.group, path: attachment.path, rev: Int(written.rev), kind: .write, entry: .file))
      }
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

// Who posts, as delivery needs it: the actor (nil for a caller that named no
// principal), the persona a person posts as, and the group posted from.
struct Poster {
  var actor: Actor?
  var persona: String
  var group: GroupID

  // A person the caller did not name resolves through its persona; the
  // --dev seat is unrestricted.
  func isAdmin(of group: GroupID, in db: Database) throws -> Bool {
    switch actor {
    case .anonymous:
      return true
    case let actor?:
      return try Groups.isAdmin(actor, of: group, in: db)
    case nil:
      guard let account = try String.fetchOne(
        db, sql: "SELECT account_id FROM personas WHERE name = ?", arguments: [persona],
      ) else { return false }
      return try Groups.isHumanAdmin(AccountID(rawValue: account), of: group, in: db)
    }
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
    let readable = try Groups.reads(poster.group, in: db)
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
    case let .dm(other):
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
    var seen: Set<String> = []
    let senderKey = message.senderSession?.rawValue
    let readable = try Groups.reads(poster.group, in: db)
    var woken = try recipients(message, conversation: conversation, readable: readable, nowDate: nowDate, in: db)
      .filter { $0 != senderKey && seen.insert($0).inserted }
    let notified = conversation.members.filter { $0.kind == .user && $0.member != message.sender.id }
    if message.senderSession == nil {
      woken = try sparingTasks(woken, reachesPeople: !notified.isEmpty, in: db)
    }

    var enqueued: [SessionID] = []
    for recipient in woken {
      let owes = try owesReply(recipient, message: message, conversation: conversation, in: db)
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
        content: message.content.attachments(in: conversation.group, for: home),
      ))
      do {
        _ = try Sessions.enqueue(recipient, input: input, nowDate: nowDate, in: db)
        enqueued.append(SessionID(recipient))
      } catch SessionStoreError.archiveGraceExpired {} catch SessionStoreError.unknownSession {}
    }

    let group = try Conversations.group(of: conversation.id.rawValue, in: db)
    for member in notified {
      try Notifications.append(
        recipient: member.member,
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

  // A person never wakes a task. A post whose only recipients are tasks is
  // refused rather than stored undelivered; one that also reaches anyone else
  // goes to them alone.
  private func sparingTasks(_ keys: [String], reachesPeople: Bool, in db: Database) throws -> [String] {
    guard !keys.isEmpty else { return keys }
    let tasks = try Set(String.fetchAll(
      db,
      sql: "SELECT id FROM sessions WHERE kind = ? AND id IN (\(databaseQuestionMarks(count: keys.count)))",
      arguments: StatementArguments([SessionKind.task.rawValue] + keys),
    ))
    let others = keys.filter { !tasks.contains($0) }
    if let task = keys.first, others.isEmpty, !reachesPeople {
      throw SessionStoreError.taskTakesNoHumanInput(task)
    }
    return others
  }

  // An @mention or a reply-target wakes a session only where the poster
  // reaches it (see reaches); the box owner, DM members and the attention
  // window are reached by construction.
  private func recipients(
    _ message: MessageRecord,
    conversation: ConversationRecord,
    readable: Set<GroupID>,
    nowDate: Date,
    in db: Database,
  ) throws -> [String] {
    var keys: [String] = []
    if let owner = conversation.ownerSession {
      keys.append(owner.rawValue)
    }
    if conversation.kind == .dmUser || conversation.kind == .dmSession {
      keys.append(contentsOf: conversation.members.filter { $0.kind == .session }.map(\.member))
    }
    var addressed = try mentioned(message.content.text, in: db)
    if let replyTarget = message.replyTarget,
       let parent = try Conversations.message(id: replyTarget.rawValue, in: db),
       let session = parent.senderSession
    {
      addressed.append(session.rawValue)
    }
    for key in addressed where try reaches(key, from: readable, in: conversation, in: db) {
      keys.append(key)
    }
    if conversation.kind.isOpen {
      keys.append(contentsOf: try attentive(conversation, before: message.n, nowDate: nowDate, in: db))
    }
    return keys
  }

  // The attention window is a union: an agent stays addressable while EITHER
  // the message count OR the elapsed time is inside its bound. Tasks never
  // enter it: a task talks to its parent through their DM, and sweeping one
  // into a box turns every box post into a fan-out to the whole swarm.
  private func attentive(
    _ conversation: ConversationRecord,
    before n: Int64,
    nowDate: Date,
    in db: Database,
  ) throws -> [String] {
    let horizon = SQLiteDateFormat.string(from: nowDate.addingTimeInterval(-Double(conversation.windowSeconds)))
    return try String.fetchAll(
      db,
      sql: """
      SELECT last.sender_session_id FROM (
        SELECT sender_session_id, MAX(n) AS n, MAX(created_at) AS created_at
        FROM messages
        WHERE conversation_id = :conversation AND sender_session_id IS NOT NULL AND n < :before
        GROUP BY sender_session_id
      ) AS last
      JOIN sessions ON sessions.id = last.sender_session_id AND sessions.kind = 'agent'
      WHERE last.created_at >= :horizon
         OR (SELECT COUNT(*) FROM messages
             WHERE conversation_id = :conversation AND n > last.n AND n < :before) < :window
      """,
      arguments: [
        "conversation": conversation.id.rawValue, "before": n,
        "horizon": horizon, "window": conversation.windowMessages,
      ],
    )
  }

  private func mentioned(_ text: String, in db: Database) throws -> [String] {
    var found: [String] = []
    for candidate in MentionScanner.candidates(in: text) where try Sessions.exists(candidate, in: db) {
      found.append(candidate)
    }
    return found
  }

  private func owesReply(
    _ recipient: String,
    message: MessageRecord,
    conversation: ConversationRecord,
    in db: Database,
  ) throws -> Bool {
    guard message.kind == .message else { return false }
    guard try Sessions.record(recipient, in: db).kind == .agent else { return false }
    return conversation.ownerSession?.rawValue == recipient
  }
}

enum MentionScanner {
  // An @ mention is a whole token: a hyphenated allocation name bounded by
  // anything outside [A-Za-z0-9_-].
  static func candidates(in text: String) -> [String] {
    var names: [String] = []
    var index = text.startIndex
    while let at = text[index...].firstIndex(of: "@") {
      let before = at == text.startIndex ? nil : text[text.index(before: at)]
      var end = text.index(after: at)
      while end < text.endIndex, isNameByte(text[end]) { end = text.index(after: end) }
      let name = String(text[text.index(after: at) ..< end])
      if before.map({ !isNameByte($0) }) ?? true, name.contains("-") {
        names.append(name)
      }
      index = end
      if index >= text.endIndex { break }
    }
    return names
  }

  private static func isNameByte(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
  }
}

extension Conversations {
  static func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID, in db: Database) throws -> Bool {
    let session = try reader.map { try Sessions.exists($0, in: db) } ?? false
    if conversation.ownerSession != nil || (conversation.kind == .users && session) {
      return try Groups.reads(group, in: db).contains(conversation.group)
    }
    guard let reader else { return conversation.kind != .users && conversation.group == group }
    if conversation.members.contains(where: { $0.member == reader && (conversation.kind != .users || $0.kind == .user) }) { return true }
    return conversation.kind != .users && conversation.group == group
  }
}

private func fileConversation(_ path: String, in group: GroupID, db: Database) throws -> ConversationRecord? {
  let parts = path.split(separator: "/", omittingEmptySubsequences: true)
  guard parts.count >= 3, parts[0] == "_", parts[1] == "conversations",
        let record = try Conversations.record(String(parts[2]), in: db), record.group == group else { return nil }
  return record
}
