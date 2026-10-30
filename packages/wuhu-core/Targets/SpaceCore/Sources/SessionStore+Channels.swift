#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import StructuredQueriesSQLite

public enum ChannelError: Error, Equatable, Sendable {
  case sessionMember(String)
  case unknownPerson(String)
  case notChannel(String)
  case invalidTitle
}

enum Channels {
  static func resolve(_ people: [String], in db: Database) throws -> [String] {
    try people.map { try resolve($0, in: db) }
  }

  static func resolve(_ person: String, in db: Database) throws -> String {
    guard try !Sessions.exists(person, in: db) else { throw ChannelError.sessionMember(person) }
    guard let id = try Aliases.resolvePerson(person, in: db) else {
      throw ChannelError.unknownPerson(person)
    }
    return id
  }

  static func validate(title: String?) throws {
    if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ChannelError.invalidTitle }
  }

  static func authorized(_ id: ConversationID, as principal: Principal, in db: Database) throws -> ConversationRecord {
    guard let record = try Conversations.record(id.rawValue, in: db) else { throw SessionStoreError.unknownConversation(id.rawValue) }
    let allowed: Bool
    switch principal.actor {
    case .session, .observer, .page:
      allowed = try GroupAccess.role(of: principal.actor, in: record.group, acting: principal.group, in: db).map { $0 >= .write } ?? false
    case let .person(persona, _):
      allowed = record.members.contains { $0.member == persona && $0.kind == .user }
    case .anonymous:
      allowed = false
    }
    guard allowed else { throw SessionStoreError.unknownConversation(id.rawValue) }
    guard record.kind == .users else { throw ChannelError.notChannel(id.rawValue) }
    return record
  }
}

extension SessionStore {
  public func addChannelMembers(_ id: ConversationID, people: [String], as principal: Principal) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      _ = try Channels.authorized(id, as: principal, in: db)
      let people = try Channels.resolve(people, in: db)
      for person in people { try Conversations.join(id.rawValue, member: .init(member: person, kind: .user), now: now, in: db) }
    }
  }

  public func removeChannelMembers(_ id: ConversationID, people: [String], as principal: Principal) async throws {
    try await writer.write { db in
      _ = try Channels.authorized(id, as: principal, in: db)
      for person in people {
        guard try !Sessions.exists(person, in: db) else { throw ChannelError.sessionMember(person) }
        let ids = [person, try Aliases.target(person, kind: .person, in: db)].compactMap { $0 }
        try ConversationMemberRow.where { $0.conversationID.eq(id.rawValue) && $0.member.in(ids) }.delete().execute(db)
      }
    }
  }

  public func renameChannel(_ id: ConversationID, title: String?, as principal: Principal) async throws {
    try Channels.validate(title: title)
    try await writer.write { db in
      _ = try Channels.authorized(id, as: principal, in: db)
      try ConversationTitleRow.upsert { ConversationTitleRow(conversationID: id.rawValue, title: title) }.execute(db)
    }
  }
}
