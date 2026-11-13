#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite
import Wuwei
import WuweiQueries

extension Sessions {
  /// The session's last message in `conversation` and the one it answered (its
  /// reply target, else the message before it), oldest first. Empty when the
  /// session never posted there, posted there at or after the generation
  /// began, or the generation already shows a message from there: that one
  /// carried the exchange, or the compaction kept it.
  public static func staleExchange(
    _ conversation: ConversationID, session key: String, generation: Int64, startedAt start: Date, in db: Database,
  ) throws -> [MessageRecord] {
    guard let last = Conversations.fetch(
      db, where: "m.conversation_id = ? AND m.sender_session_id = ?",
      arguments: [.text(conversation.rawValue), .text(key)], order: "m.n DESC", limit: 1,
    ).first, last.createdAt < start else { return [] }
    let shown = !db.rows(SessionLineRow
      .join(StaleMessageRow.all) { $0.key.eq("message:" + $1.id) }
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $1.conversationID.eq(conversation.rawValue) }
      .limit(1).select { line, _ in line.position }).isEmpty
    guard !shown else { return [] }
    let answered = last.replyTarget.flatMap { Conversations.message(id: $0.rawValue, in: db) }
      ?? Conversations.fetch(db, where: "m.conversation_id = ? AND m.n < ?", arguments: [.text(conversation.rawValue), .integer(last.n)], order: "m.n DESC", limit: 1).first
    return (answered.map { [$0] } ?? []) + [last]
  }
}

extension Sessions {
  /// When the session's current generation began: its head's timestamp. A
  /// creation without a head began with the session, so nothing it posted
  /// predates it.
  public static func generationStart(_ key: String, generation: Int64, in db: Database) throws -> Date? {
    try lineText(key, generation: generation, lineKey: LineKey.head, in: db)?.at
  }

  /// The sender as the recipient is shown it, named by today's handle and device name.
  public static func attributed(_ sender: Sender, in db: Database) throws -> Sender {
    var sender = sender
    sender.handle = db.rows(AliasRow.where { $0.kind.eq(AliasKind.person) && $0.target.eq(sender.id) && $0.current }.select(\.name)).first
    if let device = sender.device { sender.deviceName = db.rows(DeviceRow.find(device)).first?.name }
    return sender
  }
}

@Table("messages")
private struct StaleMessageRow {
  let id: String
  @Column("conversation_id") let conversationID: String
}
