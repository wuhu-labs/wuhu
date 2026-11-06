#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

extension Conversations {
  /// The session's last message in `conversation` and the one it answered (its
  /// reply target, else the message before it), oldest first. Empty when the
  /// session never posted there, posted there at or after the generation
  /// began, or the generation already shows a message from there: that one
  /// carried the exchange, or the compaction kept it.
  static func staleExchange(
    _ conversation: ConversationID, session key: String, generation: Int64, startedAt start: Date, in db: Database,
  ) throws -> [MessageRecord] {
    guard let last = try fetch(
      db, where: "m.conversation_id = ? AND m.sender_session_id = ?",
      arguments: [conversation.rawValue, key], order: "m.n DESC", limit: 1,
    ).first, last.createdAt < start else { return [] }
    let shown = try Bool.fetchOne(
      db,
      sql: """
      SELECT EXISTS (SELECT 1 FROM session_pointers p
        JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
        WHERE p.session_id = ? AND p.generation = ? AND c.payload LIKE '{"message":%'
          AND json_extract(c.payload, '$.message._0.conversationID') = ?)
      """,
      arguments: [key, generation, conversation.rawValue],
    ) ?? false
    guard !shown else { return [] }
    let answered = try last.replyTarget.flatMap { try message(id: $0.rawValue, in: db) }
      ?? fetch(db, where: "m.conversation_id = ? AND m.n < ?", arguments: [conversation.rawValue, last.n], order: "m.n DESC", limit: 1).first
    return (answered.map { [$0] } ?? []) + [last]
  }
}

extension Sessions {
  /// When the session's current generation began: its head's timestamp. A
  /// creation without a head began with the session, so nothing it posted
  /// predates it.
  static func generationStart(_ key: String, generation: Int64, in db: Database) throws -> Date? {
    guard let payload = try String.fetchOne(
      db,
      sql: """
      SELECT c.payload FROM session_pointers p
      JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
      WHERE p.session_id = ? AND p.generation = ? AND p.position = 0
      """,
      arguments: [key, generation],
    ), case let .generationHead(head) = try decode(TranscriptItem.self, from: payload) else { return nil }
    return head.timestamp
  }

  /// The sender as the recipient is shown it, named by today's handle and device name.
  static func attributed(_ sender: Sender, in db: Database) throws -> Sender {
    var sender = sender
    sender.handle = try UserProfileRow.find(sender.id).fetchOne(db)?.handle
    if let device = sender.device { sender.deviceName = try DeviceRow.find(device).fetchOne(db)?.name }
    return sender
  }
}
