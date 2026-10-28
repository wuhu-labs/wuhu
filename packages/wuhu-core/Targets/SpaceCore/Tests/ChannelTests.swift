import DeterministicDependencies
import Foundation
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct ChannelTests {
  @Test func aliasesPersistCanonicalMembersSoPeopleCanResolveAndOpenTheirChannel() async throws {
    let space = try makeSpace()
    let owner = try await space.addAccount(kind: .human, name: "Minsheng")
    let key = try await space.addKey(testPubkey("channel-owner"), account: owner.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let persona = try await space.adoptPersona(key: key)
    _ = try await space.setUserProfile(principal: persona.name, handle: "minsheng", displayName: nil)
    _ = try await space.setUserProfile(principal: persona.name, handle: "renamed", displayName: nil)
    let reader = Principal.shared(.person(persona: persona.name, account: owner.id))
    let id = try await space.sessions.createConversation(members: ["MINSHENG", "renamed", persona.name], title: "Wuhu bugs", in: .shared)
    #expect(try await space.sessions.conversation(id).members.map(\.member) == [persona.name])
    #expect(try await space.query("SELECT id, title FROM conversations WHERE kind = 'users'", as: reader).rows == [[.text(id.rawValue), .text("Wuhu bugs")]])
    #expect(try await space.sessions.reads(space.sessions.conversation(id), reader: persona.name, group: .shared))
    _ = try await space.sessions.post(.conversation(id), messageID: MessageID("opened"), sender: person(persona.name), content: .init(text: "hello"), acting: reader)
    _ = try await space.setUserProfile(principal: "second-person", handle: "hazel", displayName: nil)
    await #expect(throws: ChannelError.unknownPerson("missing")) {
      try await space.sessions.addChannelMembers(id, people: ["hazel", "missing"], as: reader)
    }
    #expect(try await space.sessions.conversation(id).members.map(\.member) == [persona.name])
    try await space.sessions.addChannelMembers(id, people: ["HAZEL", "second-person"], as: reader)
    #expect(try await space.sessions.conversation(id).members.map(\.member).sorted() == [persona.name, "second-person"].sorted())
    try await space.sessions.removeChannelMembers(id, people: ["hazel"], as: reader)
    #expect(try await space.sessions.conversation(id).members.map(\.member) == [persona.name])
    await #expect(throws: ChannelError.unknownPerson("missing")) {
      try await space.sessions.createConversation(members: ["minsheng", "missing"], in: .shared)
    }
    #expect(try await space.sessions.conversations(reader: persona.name, group: .shared).map(\.id) == [id])
  }

  @Test func removingPeopleAlsoRemovesLegacyRawAliasesAndUnknownStoredMembers() async throws {
    let space = try makeSpace()
    try await space.registerPeople(["owner", "person-id"])
    _ = try await space.setUserProfile(principal: "person-id", handle: "hazel", displayName: nil)
    let id = try await space.sessions.createConversation(members: ["owner", "person-id"], in: .shared)
    let owner = Principal.shared(.person(persona: "owner", account: AccountID(rawValue: "owner")))
    try await space.writer.write { db in
      for raw in ["hazel", "no-longer-in-directory"] {
        try db.execute(sql: "INSERT INTO conversation_members VALUES (?, ?, 'user', '2026-01-01T00:00:00Z')", arguments: [id.rawValue, raw])
      }
    }
    try await space.sessions.removeChannelMembers(id, people: ["hazel", "no-longer-in-directory", "not-a-member"], as: owner)
    #expect(try await space.sessions.conversation(id).members.map(\.member) == ["owner"])
  }

  @Test func managementIsAtomicHumanOnlyAndSessionsNeverJoin() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let agent = try await store.createSession(group: .shared, title: "Helper", kind: .agent, createdBy: "alice", model: .test)
      let principal = Principal.shared(.session(agent))
      try await space.registerPeople(["alice", "bob", "carol"])
      let id = try await store.createConversation(members: ["alice", "bob"], title: "Team", in: .shared)
      #expect(try await store.conversation(id).title == "Team")
      #expect(try await store.conversation(id).members.map(\.member) == ["alice", "bob"])
      await #expect(throws: ChannelError.sessionMember(agent.rawValue)) {
        try await store.addChannelMembers(id, people: ["carol", agent.rawValue], as: principal)
      }
      #expect(try await store.conversation(id).members.map(\.member) == ["alice", "bob"])
      await #expect(throws: ChannelError.sessionMember(agent.rawValue)) {
        try await store.createConversation(members: ["alice", agent.rawValue], in: .shared)
      }
      try await store.addChannelMembers(id, people: ["carol", "carol"], as: principal)
      await #expect(throws: ChannelError.sessionMember(agent.rawValue)) {
        try await store.removeChannelMembers(id, people: ["alice", agent.rawValue], as: principal)
      }
      #expect(try await store.conversation(id).members.map(\.member) == ["alice", "bob", "carol"])
      try await store.removeChannelMembers(id, people: ["bob"], as: principal)
      try await store.renameChannel(id, title: "Renamed", as: principal)
      #expect(try await store.conversation(id).members.map(\.member) == ["alice", "carol"])
      #expect(try await store.conversation(id).title == "Renamed")
      try await store.renameChannel(id, title: nil, as: principal)
      #expect(try await store.conversation(id).title == nil)
      await #expect(throws: ChannelError.invalidTitle) { try await store.renameChannel(id, title: "  ", as: principal) }
      _ = try await store.post(.conversation(id), messageID: MessageID("reply"), sender: person(agent.rawValue), senderSession: agent, content: .init(text: "hello"))
      #expect(try await store.conversation(id).members.allSatisfy { $0.kind == .user })
      #expect(try await store.conversation(id).members.map(\.member) == ["alice", "carol"])
    }
  }

  @Test func plainMessageSleepsMentionReplyAndAttentionWakeTheAgent() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    let agent = try await store.createSession(group: .shared, title: "Helper", kind: .agent, createdBy: "alice", model: .test)
    try await rig.space.registerPeople(["alice", "bob"])
    let id = try await store.createConversation(members: ["alice", "bob"], in: .shared)
    let plain = try await store.post(.conversation(id), messageID: MessageID("plain"), sender: person("alice"), content: .init(text: "hello people"))
    #expect(plain.enqueued.isEmpty)
    #expect(try await store.hydrate(agent).undrained.isEmpty)
    let mention = try await store.post(.conversation(id), messageID: MessageID("mention"), sender: person("alice"), content: .init(text: "@\(agent.rawValue) help"))
    #expect(mention.enqueued == [agent])
    _ = try await store.drainQueue(agent)
    let answer = try await store.post(.conversation(id), messageID: MessageID("answer"), sender: person(agent.rawValue), senderSession: agent, replyTarget: mention.message.id, content: .init(text: "answer"))
    #expect(answer.message.conversation == id)
    #expect(answer.enqueued.isEmpty)
    let next = try await store.post(.conversation(id), messageID: MessageID("next"), sender: person("bob"), content: .init(text: "thanks, one more thing"))
    #expect(next.enqueued == [agent])
    rig.advance(901)
    for n in 0 ..< 10 {
      _ = try await store.post(.conversation(id), messageID: MessageID("after-\(n)"), sender: person("alice"), content: .init(text: "people talk"))
    }
    let expired = try await store.post(.conversation(id), messageID: MessageID("expired"), sender: person("alice"), content: .init(text: "just people"))
    #expect(expired.enqueued.isEmpty)
    let reply = try await store.post(.conversation(id), messageID: MessageID("reply"), sender: person("bob"), replyTarget: answer.message.id, content: .init(text: "about that answer"))
    #expect(reply.enqueued == [agent])
  }

  @Test func nonMemberCannotReadPostManageOrQueryEvenInTheHomeGroup() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      try await space.registerPeople(["alice", "bob"])
      let id = try await store.createConversation(members: ["alice", "bob"], title: "Private", in: .shared)
      let stranger = Principal.shared(.person(persona: "carol", account: AccountID(rawValue: "carol")))
      #expect(try await !store.reads(store.conversation(id), reader: "carol", group: .shared))
      await #expect(throws: SessionStoreError.unknownConversation(id.rawValue)) {
        try await store.post(.conversation(id), messageID: MessageID("bad"), sender: person("carol"), content: .init(text: "no"), acting: stranger)
      }
      await #expect(throws: SessionStoreError.unknownConversation(id.rawValue)) { try await store.renameChannel(id, title: "No", as: stranger) }
      #expect(try await space.query("SELECT id FROM conversations WHERE kind = 'users'", as: stranger).rows.isEmpty)
      #expect(try await space.query("SELECT id FROM \"wuhu://*.localspace/conversations\" WHERE kind = 'users'", as: stranger).rows.isEmpty)
      let agent = try await store.createSession(group: .shared, title: "Reader", kind: .agent, createdBy: "alice", model: .test)
      let principal = Principal.shared(.session(agent))
      #expect(try await store.reads(store.conversation(id), reader: agent.rawValue, group: .shared))
      #expect(try await space.query("SELECT id, title FROM conversations WHERE kind = 'users'", as: principal).rows == [[.text(id.rawValue), .text("Private")]])
    }
  }

  @Test func aReadableGroupAdmitsSessionsButNotItsNonMemberPeople() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let alice = try await plainGroup(space, "alice")
      let bob = try await plainGroup(space, "bob")
      let agent = try await space.sessions.createSession(group: bob, title: "Reader", kind: .agent, createdBy: "bob", model: .test)
      try await space.registerPeople(["alice"])
      let id = try await space.sessions.createConversation(members: ["alice"], title: "People", in: alice)
      #expect(try await !space.sessions.reads(space.sessions.conversation(id), reader: agent.rawValue, group: bob))
      await #expect(throws: SessionStoreError.unknownConversation(id.rawValue)) {
        try await space.sessions.post(.conversation(id), messageID: MessageID("before"), sender: person(agent.rawValue), senderSession: agent, content: .init(text: "no access"))
      }
      try await space.setGrant(.group, bob.rawValue, role: .write, in: alice, by: .anonymous, acting: alice)
      #expect(try await space.sessions.reads(space.sessions.conversation(id), reader: agent.rawValue, group: bob))
      #expect(try await !space.sessions.reads(space.sessions.conversation(id), reader: "bob", group: bob))
      let principal = Principal(actor: .session(agent), group: bob)
      #expect(try await space.query("SELECT id FROM conversations WHERE kind = 'users'", as: principal).rows == [[.text(id.rawValue)]])
      _ = try await space.sessions.post(.conversation(id), messageID: MessageID("after"), sender: person(agent.rawValue), senderSession: agent, content: .init(text: "readable"))
      #expect(try await space.sessions.conversation(id).members.map(\.member) == ["alice"])
    }
  }

  @Test func channelUnreadUsesThePersonsReadMarkerAndClears() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      try await space.registerPeople(["alice", "bob"])
      let id = try await space.sessions.createConversation(members: ["alice", "bob"], in: .shared)
      _ = try await space.sessions.post(.conversation(id), messageID: MessageID("one"), sender: person("alice"), content: .init(text: "hello"))
      #expect(try await space.sessions.unreadCount(identity: "bob", source: id.rawValue) == 1)
      try await space.sessions.advanceWatermark(identity: "bob", source: id.rawValue)
      #expect(try await space.sessions.unreadCount(identity: "bob", source: id.rawValue) == 0)
    }
  }

  @Test func notificationViewsEnforceChannelReadershipAndRevokeObservers() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let foreign = try await plainGroup(space, "foreign")
      try await space.setGrant(.group, GroupID.shared.rawValue, role: .write, in: foreign, by: .anonymous, acting: foreign)
      let agent = try await space.sessions.createSession(group: .shared, title: "Reader", kind: .agent, createdBy: "alice", model: .test)
      for group in [GroupID.shared, foreign] {
        try await space.registerPeople(["alice", "bob"])
        let id = try await space.sessions.createConversation(members: ["alice", "bob"], in: group)
        _ = try await space.sessions.post(.conversation(id), messageID: MessageID("secret-" + group.rawValue), sender: person("alice"), content: .init(text: "secret"))
        for name in ["notifications", "wuhu://\(group.rawValue).localspace/notifications", "wuhu://*.localspace/notifications"] {
          let sql = "SELECT payload FROM \"\(name)\" WHERE source = '\(id.rawValue)'"
          let bob = Principal.shared(.person(persona: "bob", account: AccountID(rawValue: "bob")))
          let carol = Principal.shared(.person(persona: "carol", account: AccountID(rawValue: "carol")))
          #expect(try await space.query(sql, as: carol).rows.isEmpty)
          #expect(try await !space.query(sql, as: bob).rows.isEmpty)
          if group == .shared || name != "notifications" {
            #expect(try await !space.query(sql, as: .shared(.session(agent))).rows.isEmpty)
          }
          for try await snapshot in await space.observeQuery(sql, throttle: .zero, as: carol) {
            #expect(snapshot.rows.isEmpty)
            break
          }
          let frames = Collector<Rows>()
          let stream = await space.observeQuery(sql, throttle: .zero, as: bob)
          let consumer = Task { do { for try await frame in stream { await frames.append(frame) } } catch { Issue.record(error) } }
          defer { consumer.cancel() }
          #expect(try await awaitItems(frames, atLeast: 1).count == 1)
          try await space.sessions.removeChannelMembers(id, people: ["bob"], as: Principal(actor: .person(persona: "alice", account: AccountID(rawValue: "alice")), group: group))
          #expect(try await awaitItems(frames, atLeast: 2).last?.rows.isEmpty == true)
          try await space.sessions.addChannelMembers(id, people: ["bob"], as: Principal(actor: .person(persona: "alice", account: AccountID(rawValue: "alice")), group: group))
        }
      }
    }
  }

  @Test func anonymousCannotReadManageOrQueryChannelsAndListsStayRecentActive() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      try await space.registerPeople(["alice", "bob"])
      let older = try await store.createConversation(members: ["alice"], title: "Older", in: .shared)
      let newer = try await store.createConversation(members: ["alice"], title: "Newer", in: .shared)
      let foreign = try await plainGroup(space, "foreign")
      let remote = try await store.createConversation(members: ["alice"], in: foreign)
      try await space.setGrant(.group, GroupID.shared.rawValue, role: .write, in: foreign, by: .anonymous, acting: foreign)
      #expect(try await !store.reads(store.conversation(older), reader: nil, group: .shared))
      for operation in [0, 1, 2] {
        await #expect(throws: SessionStoreError.unknownConversation(older.rawValue)) {
          switch operation {
          case 0: try await store.addChannelMembers(older, people: ["bob"], as: .shared(.anonymous))
          case 1: try await store.removeChannelMembers(older, people: ["alice"], as: .shared(.anonymous))
          default: try await store.renameChannel(older, title: "No", as: .shared(.anonymous))
          }
        }
      }
      #expect(try await !store.reads(store.conversation(remote), reader: nil, group: .shared))
      #expect(try await space.query("SELECT title FROM conversations WHERE id = '\(older.rawValue)'", as: .shared(.anonymous)).rows.isEmpty)
      #expect(try await space.query("SELECT id FROM \"wuhu://*.localspace/conversations\" WHERE id = '\(remote.rawValue)'", as: .shared(.anonymous)).rows.isEmpty)
      _ = try await store.post(.conversation(newer), messageID: MessageID("newer"), sender: person("alice"), content: .init(text: "newer"))
      _ = try await store.post(.conversation(older), messageID: MessageID("older"), sender: person("alice"), content: .init(text: "older"))
      #expect(try await store.conversations(reader: nil, group: .shared).isEmpty)
      #expect(try await store.conversations(reader: "alice", group: .shared).prefix(2).map(\.id) == [older, newer])
    }
  }
}

private func person(_ id: String) -> Sender { Sender(id: id, timeZone: .gmt) }

private func plainGroup(_ space: Space, _ id: String) async throws -> GroupID {
  try await space.writer.write { db in
    try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00Z')", arguments: [id])
  }
  return GroupID(rawValue: id)
}
