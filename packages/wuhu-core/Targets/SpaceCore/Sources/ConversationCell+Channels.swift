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
  /// Makes the channel this cell is keyed for, homed in `group`.
  mutating func open(members: [String], title: String?, in group: GroupID, at date: Date) throws {
    let people = try members.map(person)
    try check(title)
    let now = SQLiteDateFormat.string(from: date)
    try make(ConversationRecord(
      id: ConversationID(context.id.key), kind: .users, ownerSession: nil, title: nil, group: group,
      windowMessages: ConversationDefaults.windowMessages, windowSeconds: ConversationDefaults.windowSeconds,
      members: people.map { ConversationMember(member: $0, kind: .user) }, createdAt: date,
    ), now: now)
    try context.db.execute(ConversationTitleRow.upsert { ConversationTitleRow(conversationID: context.id.key, title: title) })
  }

  mutating func add(_ people: [String], as principal: Principal, at date: Date) throws {
    try manage(as: principal)
    let now = SQLiteDateFormat.string(from: date)
    for person in try people.map(person) { try join(ConversationMember(member: person, kind: .user), now: now) }
  }

  /// A person leaves under the name given and under the one it is an alias of; someone who is not a member is no error.
  mutating func remove(_ people: [String], as principal: Principal) throws {
    try manage(as: principal)
    for person in people {
      guard session(person) == nil else { throw ChannelError.sessionMember(person) }
      let names = [person, space.alias(ofPerson: person)].compactMap(\.self)
      try context.db.execute(ConversationMemberRow.where { $0.conversationID.eq(context.id.key) && $0.member.in(names) }.delete())
    }
  }

  mutating func rename(_ title: String?, as principal: Principal) throws {
    try check(title)
    try manage(as: principal)
    try context.db.execute(ConversationTitleRow.upsert { ConversationTitleRow(conversationID: context.id.key, title: title) })
  }

  /// A channel is managed by its people and by whoever writes its group; to anyone else it is not there.
  private func manage(as principal: Principal) throws {
    guard let record = record() else { throw SessionStoreError.unknownConversation(context.id.key) }
    let allowed: Bool
    switch principal.actor {
    case .session, .observer, .page:
      let group: GroupCell = context.cell(GroupCell.ID(record.group.rawValue))
      allowed = group.role(of: principal.actor, acting: principal.group).map { $0 >= .write } ?? false
    case let .person(persona, _):
      allowed = record.members.contains { $0.member == persona && $0.kind == .user }
    case .anonymous:
      allowed = false
    }
    guard allowed else { throw SessionStoreError.unknownConversation(context.id.key) }
    guard record.kind == .users else { throw ChannelError.notChannel(context.id.key) }
  }

  private func person(_ spelling: String) throws -> String {
    guard session(spelling) == nil else { throw ChannelError.sessionMember(spelling) }
    guard let person = space.person(spelling) else { throw ChannelError.unknownPerson(spelling) }
    return person
  }

  private func check(_ title: String?) throws {
    if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ChannelError.invalidTitle }
  }

  /// Writes a conversation that was only described until now: a new channel, a DM or a box at its first post.
  mutating func make(_ conversation: ConversationRecord, now: String) throws {
    try context.db.execute(ConversationRow.insert {
      ConversationRow(
        id: context.id.key, kind: conversation.kind.rawValue, ownerSession: conversation.ownerSession?.rawValue,
        windowMessages: conversation.windowMessages, windowSeconds: conversation.windowSeconds, createdAt: now, group: conversation.group.rawValue,
      )
    })
    for member in conversation.members { try join(member, now: now) }
  }
}
