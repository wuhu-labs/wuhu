import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite
import Wuwei
import WuweiQueries

extension SpaceCell {
  /// Whether `account` may own a group: a live person, not a guest.
  func canOwnGroup(_ account: AccountID) -> Bool {
    guard let row = GroupAccess.ActorRows(db).account(account) else { return false }
    return row.kind == "human" && row.removedAt == nil && !row.guest
  }

  /// The group a spelling names: an id or a current or retired group alias.
  func resolve(_ spelling: String) -> GroupID? {
    if let row = db.rows(GroupRow.where { $0.id.eq(spelling) }).first, row.removedAt == nil {
      return GroupID(rawValue: row.id)
    }
    guard let alias = db.rows(AliasRow.where { $0.name.eq(spelling.lowercased()) && $0.kind.eq(AliasKind.group) }).first,
          let row = db.rows(GroupRow.where { $0.id.eq(alias.target) }).first, row.removedAt == nil else { return nil }
    return GroupID(rawValue: row.id)
  }

  /// The groups an account is listed in, by any role.
  func memberGroups(of account: AccountID) -> Set<GroupID> {
    let live = Set(rows.all)
    return Set(
      db.rows(GroupRoleRow.where { $0.accountID.eq(account.rawValue) })
        .map { GroupID(rawValue: $0.grp) }
        .filter { live.contains($0) },
    )
  }

  func isGuest(_ account: AccountID) -> Bool {
    GroupAccess.ActorRows(db).account(account)?.guest ?? false
  }

  /// The group a session acts in.
  func group(of session: SessionID) -> GroupID {
    db.rows(GroupSessionRow.where { $0.id.eq(session.rawValue) }).first.map { GroupID(rawValue: $0.grp) } ?? .shared
  }
}

// What only the space as a whole can answer: a message by its own id, requests by the task or the
// requester they name, and the documents a move would carry under a path. A question about one
// conversation, person, group or document is that addressable's own read.
extension SpaceCell {
  /// Every conversation, or those naming a session member, most recently written first.
  func conversations(member: String? = nil) -> [ConversationID] {
    db.rows(
      ConversationRow.where {
        #sql("""
        \(bind: member) IS NULL OR EXISTS (
          SELECT 1 FROM conversation_members
          WHERE conversation_id = \($0.id) AND member_kind = 'session' AND member = \(bind: member)
        )
        """, as: Bool.self)
      }.order {
        #sql("COALESCE((SELECT MAX(n) FROM messages WHERE conversation_id = \($0.id)), 0)", as: Int64.self).desc()
      }.select { $0.id },
    ).map { ConversationID($0) }
  }

  /// The conversation a DM spelling names: a session's id, a persona's name or an alias; nil for nobody.
  func directMessageTarget(_ spelling: String) -> String? {
    directoryTarget(spelling, sessions: true)
  }

  /// The message with `id`, whichever conversation holds it.
  func message(_ id: MessageID) -> MessageRecord? {
    db.rows("\(Conversations.selection) WHERE m.id = ?", .text(id.rawValue)).first.map(MessageRecord.init(row:))
  }

  /// The request with `id`, whichever conversation holds it.
  func request(_ id: RequestID) -> RequestRow? {
    db.rows(RequestRow.where { $0.id.eq(id.rawValue) }).first
  }

  /// The requests `requester` opened that still wait on their final, oldest first.
  func awaitedRequests(of requester: String) -> [AwaitedRequest] {
    db.rows(
      """
      SELECT r.id, r.task,
        COALESCE((SELECT MAX(m.created_at) FROM messages AS m WHERE m.request_id = r.id AND m.kind = 'progress'), r.created_at) AS heard
      FROM requests AS r WHERE r.requester = ? AND r.status = 'open' ORDER BY r.created_at, r.id
      """,
      .text(requester),
    ).map {
      AwaitedRequest(
        id: RequestID($0["id"].text!), task: SessionID($0["task"].text!),
        lastHeard: try! SQLiteDateFormat.date(from: $0["heard"].text!),
      )
    }
  }

  /// The requests `task` has open, oldest first.
  func openRequests(of task: String) throws -> [OpenRequest] {
    guard !db.rows(GroupSessionRow.where { $0.id.eq(task) }).isEmpty else {
      throw SessionStoreError.unknownSession(task)
    }
    return db.rows(
      RequestRow.where { $0.task.eq(task) && $0.status.in(RequestStatus.allCases.filter(\.isOpen).map(\.rawValue)) }
        .order { $0.createdAt }
        .select { $0.id },
    ).map { OpenRequest(id: RequestID($0)) }
  }

  /// The documents at `path` and under it in `group` that hold edits their files lack.
  func dirtyDocuments(in group: GroupID, under path: SpacePath) -> [String] {
    let range = DocumentRows.range(group, path)
    return db.rows(
      DocumentStateRow.unscoped.where {
        (#sql("owner", as: String.self).eq(range.exact) ||
          (#sql("owner", as: String.self).gte(range.below) && #sql("owner", as: String.self).lt(range.belowUpper)))
          && $0.dirtyAt.isNot(nil)
      }.select { _ in #sql("owner", as: String.self) },
    )
  }
}

extension SessionStore {
  /// The space's own cell: what spans its groups.
  var spaceCell: SpaceCell { runtime.worker().cell(SpaceCell.ID("space")) }
}
