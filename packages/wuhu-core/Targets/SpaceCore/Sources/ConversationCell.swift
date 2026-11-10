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
  var acting: Principal?
  var request: RequestStep?
  var at: Date
}

/// What a post does to the request it belongs to, in the step that writes its message.
enum RequestStep: Sendable {
  case open(group: GroupID, requester: Caller, task: SessionID, brief: String, terms: RequestTerms, stallSeconds: Double?)
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
  func record() -> ConversationRecord? {
    guard let row = db.rows(ConversationRow.where { $0.id.eq(id.key) }).first else { return nil }
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

  /// Where `post` would land and whether it already did, refusing as `post(_:)` would: what main needs to write a post's attachments first.
  func placing(_ post: Post) throws -> (group: GroupID, replayed: Bool) {
    (try admit(post, poster: poster(of: post)).conversation.group, message(post.messageID) != nil)
  }

  mutating func attached(_ socket: SocketHandle<ConversationTail>) {
    guard let record = record(), reads(record, as: socket.opening.viewer) else { return socket.close() }
    let missed = messages(where: "m.n > ?", .integer(socket.opening.after), limit: nil)
    if !missed.isEmpty { socket.send(missed) }
  }

  mutating func post(_ post: Post) throws -> MessageDelivery {
    let poster = poster(of: post)
    let admitted = try admit(post, poster: poster)
    let conversation = admitted.conversation
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
    if admitted.isNew {
      try db.execute(ConversationRow.insert {
        ConversationRow(
          id: id.key, kind: conversation.kind.rawValue, ownerSession: nil,
          windowMessages: conversation.windowMessages, windowSeconds: conversation.windowSeconds, createdAt: now, group: conversation.group.rawValue,
        )
      })
      for member in conversation.members {
        try join(member, now: now)
      }
    }
    if conversation.kind == .box {
      try join(ConversationMember(member: post.senderSession?.rawValue ?? post.sender.id, kind: post.senderSession == nil ? .user : .session), now: now)
    }
    try db.execute(
      """
      INSERT INTO messages
        (id, conversation_id, sender_id, sender_session_id, sender_timezone,
         reply_target, kind, request_id, content, created_at, firing)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      .text(post.messageID.rawValue), .text(id.key), .text(post.sender.id), text(post.senderSession?.rawValue),
      .text(post.sender.timeZone.identifier), text(post.replyTarget?.rawValue), .text(post.kind.rawValue), text(post.requestID?.rawValue),
      .text(try Sessions.encode(post.content)), .text(now), text(poster.firing),
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

// MARK: Its pages

extension ConversationCell {
  private func reads(_ conversation: ConversationRecord, as viewer: Principal?) -> Bool {
    guard let viewer else { return true }
    let reader = viewer.member
    let isSession = reader.map { session($0) != nil } ?? false
    return conversation.reads(reader, isSession: isSession, group: viewer.group) {
      guard let reader, !isSession, let account = account(of: reader) else { return space.reach(of: viewer.group) }
      return space.readable(by: Principal(actor: .person(persona: reader, account: account), group: viewer.group))
    }
  }

  /// The messages after sequence `n`, oldest first.
  func messages(after n: Int64, limit: Int?) throws -> [MessageRecord] {
    try known()
    return messages(where: "m.n > ?", .integer(n), limit: limit)
  }

  /// The last `limit` messages before sequence `n`, or the newest; oldest first.
  func tail(before n: Int64?, limit: Int) throws -> [MessageRecord] {
    try known()
    return messages(where: "m.n < ?", .integer(n ?? .max), newestFirst: true, limit: limit).reversed()
  }

  /// Anchors resolve to the message sequence, so messages sharing a timestamp are never split across pages. A message id from another conversation is `unknownMessage`.
  func page(from cursor: MessageCursor, limit: Int) throws -> MessagePage {
    precondition(limit > 0, "a page holds at least one message")
    try known()
    let rows: [MessageRecord]
    switch cursor {
    case .latest:
      rows = messages(where: "m.n < ?", .integer(.max), newestFirst: true, limit: limit + 1)
    case let .after(anchor):
      rows = messages(where: "m.n > ?", .integer(try sequence(anchor, bound: "MAX(n)", comparing: "<=") ?? 0), limit: limit + 1)
      let page = Array(rows.prefix(limit))
      return MessagePage(messages: page, next: rows.count > limit ? page.last?.id : nil)
    case let .before(anchor):
      rows = messages(where: "m.n < ?", .integer(try sequence(anchor, bound: "MIN(n)", comparing: ">=") ?? .max), newestFirst: true, limit: limit + 1)
    }
    let page = Array(rows.prefix(limit).reversed())
    return MessagePage(messages: page, next: rows.count > limit ? page.first?.id : nil)
  }

  private func known() throws {
    guard db.one("SELECT 1 FROM conversations WHERE id = ?", .text(id.key)) != nil else { throw SessionStoreError.unknownConversation(id.key) }
  }

  private func messages(where condition: String, _ bound: Value, newestFirst: Bool = false, limit: Int?) -> [MessageRecord] {
    db.rows(
      "\(Conversations.selection) WHERE m.conversation_id = ? AND \(condition) ORDER BY m.n \(newestFirst ? "DESC" : "ASC") LIMIT ?",
      .text(id.key), bound, .integer(Int64(limit ?? -1)),
    ).map(MessageRecord.init(row:))
  }

  /// The sequence an anchor stands at: a message's own, or the last at or before (first at or after) a time. `created_at` rows written before fractional seconds were stored sort wrong as text against newer ones, so times compare through julianday; a time parsed from "…16.326Z" can land a hair under .326 and the format truncates, so it rounds to the millisecond the rows are stored in.
  private func sequence(_ anchor: MessageAnchor, bound: String, comparing: String) throws -> Int64? {
    switch anchor {
    case let .message(message):
      guard let n = db.one("SELECT n FROM messages WHERE id = ? AND conversation_id = ?", .text(message.rawValue), .text(id.key))?.integer else {
        throw SessionStoreError.unknownMessage(message.rawValue)
      }
      return n
    case let .time(date):
      return db.one(
        "SELECT \(bound) FROM messages WHERE conversation_id = ? AND julianday(created_at) \(comparing) julianday(?)",
        .text(id.key), .text(SQLiteDateFormat.string(from: date.addingTimeInterval(0.0005))),
      )?.integer
    }
  }
}

// MARK: Who may post

extension ConversationCell {
  struct Poster {
    var actor: Actor?
    var persona: String
    var group: GroupID

    var firing: String? {
      if case let .observer(observer)? = actor { observer.firing } else { nil }
    }
  }

  private struct Admitted {
    var conversation: ConversationRecord
    /// A DM its first post is about to make.
    var isNew = false
  }

  private func poster(of post: Post) -> Poster {
    Poster(
      actor: post.senderSession.map(Actor.session) ?? post.acting?.actor,
      persona: post.sender.id,
      group: post.senderSession.map { group(ofSession: $0.rawValue) } ?? post.acting?.group ?? .shared,
    )
  }

  private var space: SpaceCell {
    ctx.cell(SpaceCell.ID("space"))
  }

  /// The groups the poster reads: its account's entries and its acting group's reach.
  private func readable(by poster: Poster) -> Set<GroupID> {
    switch poster.actor {
    case .anonymous:
      return space.reach(of: poster.group)
    case let actor?:
      return space.readable(by: Principal(actor: actor, group: poster.group))
    case nil:
      guard let account = account(of: poster.persona) else { return space.reach(of: poster.group) }
      return space.readable(by: Principal(actor: .person(persona: poster.persona, account: account), group: poster.group))
    }
  }

  private func isAdmin(_ poster: Poster, of group: GroupID) -> Bool {
    let cell: GroupCell = ctx.cell(GroupCell.ID(group.rawValue))
    switch poster.actor {
    case .anonymous:
      return true
    case let actor?:
      return cell.role(of: actor, acting: poster.group) == .admin
    case nil:
      return account(of: poster.persona).map(cell.isHumanAdmin) ?? false
    }
  }

  private func account(of persona: String) -> AccountID? {
    db.rows(PersonaRow.where { $0.name.eq(persona) }).first.map { AccountID(rawValue: $0.accountID) }
  }

  private func session(_ key: String) -> PostSessionRow? {
    db.rows(PostSessionRow.where { $0.id.eq(key) }).first
  }

  private func group(ofSession key: String) -> GroupID {
    GroupID(rawValue: session(key)?.group ?? GroupID.shared.rawValue)
  }

  /// A conversation is there for a poster whose group reads its group, or who is a member; anything else is refused as missing. No dialing in: a DM to a session outside what the poster's group reads is opened or used only when that session has posted in it.
  private func admit(_ post: Post, poster: Poster) throws -> Admitted {
    let me = post.senderSession?.rawValue ?? post.sender.id
    let readable = readable(by: poster)
    switch post.target {
    case .conversation:
      guard let record = record(), readable.contains(record.group) || record.members.contains(where: { $0.member == me }) else {
        throw SessionStoreError.unknownConversation(id.key)
      }
      if record.kind == .users && post.senderSession == nil && !record.members.contains(where: { $0.member == me && $0.kind == .user }) {
        throw SessionStoreError.unknownConversation(id.key)
      }
      if record.kind == .dmUser || record.kind == .dmSession {
        for other in record.members where other.kind == .session && other.member != me {
          guard reaches(other.member, from: readable, in: record) else { throw SessionStoreError.unknownConversation(id.key) }
        }
      }
      return Admitted(conversation: record)
    case .box:
      guard let owner = session(id.key), readable.contains(GroupID(rawValue: owner.group)) else { throw SessionStoreError.unknownSession(id.key) }
      guard owner.kind == .agent else {
        throw post.senderSession == nil ? SessionStoreError.taskTakesNoHumanInput(id.key) : SessionStoreError.taskHasNoBox(id.key)
      }
      guard let record = record() else { throw SessionStoreError.unknownConversation(id.key) }
      return Admitted(conversation: record)
    case let .dm(other):
      precondition(id.key == Conversations.dmID(me, other).rawValue, "a DM's cell is keyed by its two members")
      let existing = record()
      let theirs = session(other)
      if let theirs {
        let reached = existing.map { reaches(other, from: readable, in: $0) } ?? readable.contains(GroupID(rawValue: theirs.group))
        guard reached else { throw SessionStoreError.unknownSession(other) }
      }
      if let existing { return Admitted(conversation: existing) }
      let mine: MemberKind = session(me) == nil ? .user : .session
      let their: MemberKind = theirs == nil ? .user : .session
      return Admitted(
        conversation: ConversationRecord(
          id: ConversationID(id.key), kind: mine == .session && their == .session ? .dmSession : .dmUser, ownerSession: nil, title: nil,
          group: poster.group, windowMessages: ConversationDefaults.windowMessages, windowSeconds: ConversationDefaults.windowSeconds,
          members: [ConversationMember(member: me, kind: mine), ConversationMember(member: other, kind: their)].sorted { $0.member < $1.member },
          createdAt: post.at,
        ),
        isNew: true,
      )
    }
  }

  /// Whether a post from a group reading `readable` may reach session `key` here: its group is readable, it owns the conversation, or it has posted in it.
  private func reaches(_ key: String, from readable: Set<GroupID>, in conversation: ConversationRecord) -> Bool {
    if conversation.ownerSession?.rawValue == key { return true }
    if readable.contains(group(ofSession: key)) { return true }
    return db.one("SELECT 1 FROM messages WHERE conversation_id = ? AND sender_session_id = ? LIMIT 1", .text(id.key), .text(key)) != nil
  }

  private mutating func join(_ member: ConversationMember, now: String) throws {
    try db.execute(ConversationMemberRow.insert {
      ConversationMemberRow(conversationID: id.key, member: member.member, kind: member.kind.rawValue, joinedAt: now)
    } onConflict: {
      ($0.conversationID, $0.member)
    })
  }
}

// MARK: Who hears it

extension ConversationCell {
  private mutating func deliver(_ message: MessageRecord, conversation: ConversationRecord, poster: Poster, at now: Date) throws -> [SessionID] {
    let routingDate = try SQLiteDateFormat.date(from: SQLiteDateFormat.string(from: now))
    let snapshot = try routingSnapshot(message, conversation: conversation, poster: poster, now: routingDate)
    let routed = try recipients(snapshot: snapshot, message: message, now: routingDate)

    let requestTask = message.kind == .request ? message.requestID.flatMap { request($0) }?.task : nil
    var enqueued: [SessionID] = []
    for key in routed.woken {
      // Only the task is handed a request; anyone else it reaches reads a message.
      let handed = message.kind != .request || requestTask == key.rawValue
      let kind = handed ? message.kind : .message
      let home = group(ofSession: key.rawValue)
      let input = QueueInput.message(ConversationMessage(
        id: .deterministic("deliver", message.id.rawValue, key.rawValue),
        messageID: message.id,
        conversationID: conversation.id,
        sender: message.sender,
        senderSession: message.senderSession,
        timestamp: message.createdAt,
        kind: kind,
        requestID: handed ? message.requestID : nil,
        replyTarget: message.replyTarget,
        owesReply: kind == .message && snapshot.sessions[key]?.kind == .agent && conversation.ownerSession == key,
        senderGroup: poster.group == home ? nil : poster.group,
        senderAdmin: isAdmin(poster, of: home),
        viewing: message.viewing?.named(for: home),
        content: message.content.attachments(in: conversation.group, for: home),
      ))
      if try put(SessionPut(input), to: key.rawValue, at: now) { enqueued.append(key) }
    }

    let note = PersonNote(
      source: conversation.id.rawValue, group: conversation.group, kind: .conversationMessage,
      payload: try Notifications.conversationPayload(
        messageID: message.id, conversation: conversation.id,
        sender: message.sender.id, senderGroup: poster.group == conversation.group ? nil : poster.group,
        text: message.content.text,
      ),
      createdAt: SQLiteDateFormat.string(from: now),
    )
    for member in routed.notified {
      ctx.send(PersonCell.ID(member)).notify(note)
    }
    return enqueued
  }

  /// Mails the session's cell an input, unless the session is gone or archived past its grace.
  private mutating func put(_ put: SessionPut, to session: String, at now: Date) throws -> Bool {
    guard let row = self.session(session) else { return false }
    if row.lifecycle != "live", let grace = row.graceExpiresAt, now >= (try SQLiteDateFormat.date(from: grace)) { return false }
    ctx.send(.put(put), to: Recipient<SessionMail>(kind: SessionMail.kind, key: session))
    return true
  }

  private func routingSnapshot(_ message: MessageRecord, conversation: ConversationRecord, poster: Poster, now: Date) throws -> RoutingSnapshot {
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
    let replySender: RoutingSnapshot.ReplySender = message.replyTarget.flatMap { self.message($0)?.senderSession }.map { .session($0) } ?? .unaddressed
    let before = message.n
    let tail = db.rows(#sql("""
    SELECT sender_session_id, created_at FROM messages
    WHERE \(conversation.kind.isOpen) AND conversation_id = \(bind: id.key) AND n < \(bind: before)
    ORDER BY n DESC LIMIT \(bind: max(0, conversation.windowMessages))
    """, as: RoutingMessage.self))
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
    let readable = readable(by: poster)
    let sessions = db.rows(PostSessionRow.where { $0.id.in(candidates) }).map { row in
      (SessionID(row.id), (kind: row.kind, reachable: reaches(row.id, from: readable, in: conversation)))
    }
    let postedByPerson: Bool = if case .observer? = poster.actor { false } else { message.senderSession == nil }
    let writes = try conversation.kind == .box ? boxWrites(
      before: before, since: now.addingTimeInterval(-RoutingSnapshot.boxNotificationSeconds), needsLatest: !postedByPerson,
    ) : []
    return RoutingSnapshot(
      audience: audience, people: conversation.members.filter { $0.kind == .user }.map(\.member),
      writes: writes, postedByPerson: postedByPerson,
      sessions: Dictionary(uniqueKeysWithValues: sessions), replySender: replySender, recentSenders: recent,
    )
  }

  /// A person post has no sender session and no observer firing. The tail stops at the last post before `since`; only a window without one walks back to the latest. `+sender_session_id` keeps both on the box's index: unanalyzed, SQLite would pick `messages_by_sender_session` and scan the whole space's person posts.
  private func boxWrites(before: Int64, since: Date, needsLatest: Bool) throws -> [RoutingSnapshot.Write] {
    let horizon = SQLiteDateFormat.string(from: since)
    var posts = db.rows(#sql("""
    SELECT sender_id, n, created_at FROM messages
    WHERE conversation_id = \(bind: id.key) AND n < \(bind: before)
      AND +sender_session_id IS NULL AND firing IS NULL
      AND n > COALESCE((
        SELECT n FROM messages
        WHERE conversation_id = \(bind: id.key) AND n < \(bind: before) AND created_at < \(bind: horizon)
        ORDER BY n DESC LIMIT 1
      ), 0)
    ORDER BY n DESC
    """, as: PersonPost.self))
    if posts.isEmpty, needsLatest {
      posts = db.rows(#sql("""
      SELECT sender_id, n, created_at FROM messages
      WHERE conversation_id = \(bind: id.key) AND n < \(bind: before)
        AND +sender_session_id IS NULL AND firing IS NULL
      ORDER BY n DESC LIMIT 1
      """, as: PersonPost.self))
    }
    var seen: Set<String> = []
    return try posts.filter { seen.insert($0.person).inserted }.map {
      (person: $0.person, n: $0.n, at: try SQLiteDateFormat.date(from: $0.createdAt))
    }
  }
}

// MARK: Its request

extension ConversationCell {
  private func request(_ id: RequestID) -> RequestRow? {
    db.rows(RequestRow.where { $0.id.eq(id.rawValue) }).first
  }

  /// The request's row changes with the message that says so: a replayed message never comes here.
  private mutating func step(_ step: RequestStep, of id: RequestID, at date: Date) throws {
    let now = SQLiteDateFormat.string(from: date)
    switch step {
    case let .open(group, requester, task, brief, terms, stallSeconds):
      if request(id) == nil {
        try db.execute(RequestRow.insert {
          RequestRow(
            id: id.rawValue, group: group.rawValue, requester: requester.name, firing: requester.firing, task: task.rawValue,
            status: RequestStatus.open.rawValue, brief: brief,
            schema: terms.schema?.jsonString(sortedKeys: true), fields: terms.fields?.jsonString(sortedKeys: true),
            result: nil, refusals: "[]", stallSeconds: stallSeconds,
            createdAt: now, updatedAt: now,
          )
        })
      }
      try remindQuiet(request(id)!, from: date)
    case .progress:
      if let row = request(id) { try remindQuiet(row, from: date) }
    case let .close(status, result):
      guard let row = request(id) else { return }
      try db.execute(RequestRow.update {
        $0.status = #bind(status.rawValue)
        $0.result = #bind(result)
        $0.updatedAt = #bind(now)
      }.where { $0.id.eq(row.id) })
      if session(row.requester) != nil {
        ctx.send(.clear(Sessions.quietTopic(row.id)), to: Recipient<SessionMail>(kind: SessionMail.kind, key: row.requester))
      }
    }
  }

  /// Puts the requester's reminder that the task has reported nothing on the request for its stall seconds since `from`; a later put moves it, the request's end takes it back. Only a live requesting session gets one.
  private mutating func remindQuiet(_ row: RequestRow, from: Date) throws {
    guard let seconds = row.stallSeconds, session(row.requester)?.lifecycle == "live" else { return }
    _ = try put(Sessions.quietReminder(row, seconds: seconds, from: from), to: row.requester, at: from)
  }
}

@Table("sessions")
private struct PostSessionRow {
  @Column(primaryKey: true) var id: String
  var kind: SessionKind
  @Column("grp") var group: String
  var lifecycle: String
  @Column("grace_expires_at") var graceExpiresAt: String?
}

@Selection
private struct RoutingMessage {
  var session: String?
  var createdAt: String
}

@Selection
private struct PersonPost {
  var person: String
  var n: Int64
  var createdAt: String
}

extension SessionKind: QueryBindable {}

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
