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

extension ConversationCell {
  mutating func deliver(_ message: MessageRecord, conversation: ConversationRecord, poster: Poster, at now: Date) throws -> [SessionID] {
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
      guard let person = ctx.cell(SpaceCell.ID("space")).personCell(member) else { continue }
      ctx.send(person).notify(member, note)
    }
    return enqueued
  }

  /// Mails the session's cell an input, unless the session is gone or archived past its grace.
  mutating func put(_ put: SessionPut, to session: String, at now: Date) throws -> Bool {
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
