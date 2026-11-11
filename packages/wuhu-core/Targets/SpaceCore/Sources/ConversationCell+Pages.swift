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
  func reads(_ conversation: ConversationRecord, as viewer: Principal?) -> Bool {
    guard let viewer else { return true }
    return reads(conversation, reader: viewer.member, group: viewer.group)
  }

  /// Box, DM and channel readership for a session id, a persona, or nil (the --dev seat) acting in `group`.
  func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID) -> Bool {
    let isSession = reader.map { session($0) != nil } ?? false
    return conversation.reads(reader, isSession: isSession, group: group) {
      guard let reader, !isSession, let account = account(of: reader) else { return space.reach(of: group) }
      return space.readable(by: Principal(actor: .person(persona: reader, account: account), group: group))
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
    guard isWritten || unopenedBox() != nil else { throw SessionStoreError.unknownConversation(id.key) }
  }

  var isWritten: Bool {
    db.one("SELECT 1 FROM conversations WHERE id = ?", .text(id.key)) != nil
  }

  func unopenedBox() -> ConversationRecord? {
    guard let owner = session(id.key), owner.kind == .agent else { return nil }
    return ConversationRecord(
      id: ConversationID(id.key), kind: .box, ownerSession: SessionID(id.key), title: nil, group: GroupID(rawValue: owner.group),
      windowMessages: ConversationDefaults.windowMessages, windowSeconds: ConversationDefaults.windowSeconds,
      members: [ConversationMember(member: id.key, kind: .session)], createdAt: try! SQLiteDateFormat.date(from: owner.createdAt),
    )
  }

  func messages(where condition: String, _ bound: Value, newestFirst: Bool = false, limit: Int?) -> [MessageRecord] {
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
