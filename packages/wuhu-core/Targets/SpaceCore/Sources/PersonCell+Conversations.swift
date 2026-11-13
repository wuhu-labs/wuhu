import SessionDomain
import StructuredQueries

extension PersonCell {
  /// Conversations naming this account or any of its personas, most recently written first.
  func conversations() -> [ConversationID] {
    let member = id.key
    return db.rows(
      ConversationRow
        .where {
          $0.id.in(ConversationMemberRow.where {
            $0.kind.eq("user") && ($0.member.eq(member) || $0.member.in(PersonaRow.where { $0.accountID.eq(member) }.select { $0.name }))
          }.select { $0.conversationID })
        }
        .order {
          #sql("COALESCE((SELECT MAX(n) FROM messages WHERE conversation_id = \($0.id)), 0)", as: Int64.self).desc()
        }
        .select { $0.id },
    ).map { ConversationID($0) }
  }
}
