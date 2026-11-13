import SessionDomain
import StructuredQueries

extension GroupCell {
  /// The conversations homed here that hold an attachment, by id.
  func attachmentConversations() -> [ConversationID] {
    let group = id.key
    return db.rows(
      ConversationRow
        .where { $0.group.eq(group) && $0.id.in(AttachmentRow.all.select { $0.conversationID }) }
        .order { $0.id }
        .select { $0.id },
    ).map { ConversationID($0) }
  }
}
