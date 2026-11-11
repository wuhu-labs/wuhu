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
  struct Poster {
    var actor: Actor?
    var persona: String
    var group: GroupID

    var firing: String? {
      if case let .observer(observer)? = actor { observer.firing } else { nil }
    }
  }

  func poster(of post: Post) -> Poster {
    Poster(
      actor: post.senderSession.map(Actor.session) ?? post.acting?.actor,
      persona: post.sender.id,
      group: post.senderSession.map { group(ofSession: $0.rawValue) } ?? post.acting?.group ?? .shared,
    )
  }

  var space: SpaceCell {
    ctx.cell(SpaceCell.ID("space"))
  }

  /// The groups the poster reads: its account's entries and its acting group's reach.
  func readable(by poster: Poster) -> Set<GroupID> {
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

  func isAdmin(_ poster: Poster, of group: GroupID) -> Bool {
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

  func account(of persona: String) -> AccountID? {
    db.rows(PersonaRow.where { $0.name.eq(persona) }).first.map { AccountID(rawValue: $0.accountID) }
  }

  func session(_ key: String) -> PostSessionRow? {
    db.rows(PostSessionRow.where { $0.id.eq(key) }).first
  }

  func group(ofSession key: String) -> GroupID {
    GroupID(rawValue: session(key)?.group ?? GroupID.shared.rawValue)
  }

  /// A conversation is there for a poster whose group reads its group, or who is a member; anything else is refused as missing. No dialing in: a DM to a session outside what the poster's group reads is opened or used only when that session has posted in it.
  func admit(_ post: Post, poster: Poster) throws -> ConversationRecord {
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
      return record
    case .box:
      guard let owner = session(id.key), readable.contains(GroupID(rawValue: owner.group)) else { throw SessionStoreError.unknownSession(id.key) }
      guard owner.kind == .agent else {
        throw post.senderSession == nil ? SessionStoreError.taskTakesNoHumanInput(id.key) : SessionStoreError.taskHasNoBox(id.key)
      }
      return record()!
    case let .dm(other):
      precondition(id.key == Conversations.dmID(me, other).rawValue, "a DM's cell is keyed by its two members")
      let existing = record()
      let theirs = session(other)
      if let theirs {
        let reached = existing.map { reaches(other, from: readable, in: $0) } ?? readable.contains(GroupID(rawValue: theirs.group))
        guard reached else { throw SessionStoreError.unknownSession(other) }
      }
      if let existing { return existing }
      let mine: MemberKind = session(me) == nil ? .user : .session
      let their: MemberKind = theirs == nil ? .user : .session
      return ConversationRecord(
        id: ConversationID(id.key), kind: mine == .session && their == .session ? .dmSession : .dmUser, ownerSession: nil, title: nil,
        group: poster.group, windowMessages: ConversationDefaults.windowMessages, windowSeconds: ConversationDefaults.windowSeconds,
        members: [ConversationMember(member: me, kind: mine), ConversationMember(member: other, kind: their)].sorted { $0.member < $1.member },
        createdAt: post.at,
      )
    }
  }

  /// Whether a post from a group reading `readable` may reach session `key` here: its group is readable, it owns the conversation, or it has posted in it.
  func reaches(_ key: String, from readable: Set<GroupID>, in conversation: ConversationRecord) -> Bool {
    if conversation.ownerSession?.rawValue == key { return true }
    if readable.contains(group(ofSession: key)) { return true }
    return db.one("SELECT 1 FROM messages WHERE conversation_id = ? AND sender_session_id = ? LIMIT 1", .text(id.key), .text(key)) != nil
  }

  mutating func join(_ member: ConversationMember, now: String) throws {
    try db.execute(ConversationMemberRow.insert {
      ConversationMemberRow(conversationID: id.key, member: member.member, kind: member.kind.rawValue, joinedAt: now)
    } onConflict: {
      ($0.conversationID, $0.member)
    })
  }
}

@Table("sessions")
struct PostSessionRow {
  @Column(primaryKey: true) var id: String
  var kind: SessionKind
  var parent: String?
  @Column("created_by") var createdBy: String
  @Column("grp") var group: String
  var lifecycle: String
  @Column("grace_expires_at") var graceExpiresAt: String?
  @Column("created_at") var createdAt: String
}

extension SessionKind: QueryBindable {}
