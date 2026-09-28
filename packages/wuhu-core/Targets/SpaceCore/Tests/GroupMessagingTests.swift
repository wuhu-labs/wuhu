import Foundation
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

// P is a top-level agent in alice, which reads shared; S is one in shared,
// which reads nothing else.
@Suite struct GroupMessagingTests {
  static let alice = GroupID(rawValue: "alice")
  static let bob = GroupID(rawValue: "bob")
  static let utc = TimeZone(identifier: "UTC")!

  struct Rig {
    let space: Space
    let p: SessionID
    let s: SessionID
    var store: SessionStore { space.sessions }
  }

  func makeRig() async throws -> Rig {
    let space = try makeSpace()
    try await space.writer.write { db in
      for group in [Self.alice, Self.bob] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00.000Z')", arguments: [group.rawValue])
      }
    }
    try await space.addEdge(src: Self.alice, dst: .shared, kind: .read, by: nil)
    let p = try await space.sessions.createSession(group: Self.alice, title: "P", kind: .agent, createdBy: "owner", model: .test)
    let s = try await space.sessions.createSession(group: .shared, title: "S", kind: .agent, createdBy: "owner", model: .test)
    return Rig(space: space, p: p, s: s)
  }

  func sender(_ id: SessionID) -> Sender { Sender(id: id.rawValue, timeZone: Self.utc) }

  func queued(_ rig: Rig, _ id: SessionID) async throws -> [ConversationMessage] {
    try await rig.store.undrainedInputs(id).compactMap {
      if case let .message(message) = $0.input { message } else { nil }
    }
  }

  @Test func sharedCannotDialIntoAlice() async throws {
    let rig = try await makeRig()
    let ids = try await rig.space.query("SELECT id FROM sessions", as: Principal(actor: .session(rig.s), group: .shared)).rows
    #expect(ids == [[.text(rig.s.rawValue)]])
    await #expect(throws: SessionStoreError.unknownSession(rig.p.rawValue)) {
      _ = try await rig.store.post(
        .dm(with: rig.p.rawValue), messageID: MessageID("m1"), sender: sender(rig.s), senderSession: rig.s,
        content: .init(text: "hi"),
      )
    }
    await #expect(throws: SessionStoreError.unknownSession(rig.p.rawValue)) {
      _ = try await rig.store.post(
        .box(rig.p), messageID: MessageID("m2"), sender: sender(rig.s), senderSession: rig.s, content: .init(text: "hi"),
      )
    }
    let mention = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m3"), sender: Sender(id: "carol", timeZone: Self.utc),
      content: .init(text: "@\(rig.p.rawValue) look"),
    )
    #expect(mention.enqueued == [rig.s])
    let box = try await rig.store.conversation(ConversationID(rig.p.rawValue))
    #expect(try await !rig.store.reads(box, reader: rig.s.rawValue, group: .shared))
  }

  @Test func aliceReachesSharedAndIsHeardBack() async throws {
    let rig = try await makeRig()
    let post = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m1"), sender: sender(rig.p), senderSession: rig.p, content: .init(text: "hello"),
    )
    #expect(post.enqueued == [rig.s])
    let heard = try #require(try await queued(rig, rig.s).last)
    #expect(heard.senderGroup == Self.alice)
    #expect(heard.senderAdmin == false)
    #expect(heard.header.render().contains("<sender-group>alice</sender-group>\n<sender-admin>no</sender-admin>"))

    let reply = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m2"), sender: sender(rig.s), senderSession: rig.s,
      replyTarget: MessageID("m1"), content: .init(text: "hi back"),
    )
    #expect(reply.enqueued == [rig.p])
    let back = try #require(try await queued(rig, rig.p).last)
    #expect(back.senderGroup == .shared)
    #expect(back.senderAdmin == false)

    let box = try await rig.store.conversation(ConversationID(rig.s.rawValue))
    #expect(try await rig.store.reads(box, reader: rig.p.rawValue, group: Self.alice))
    // P reads the box it posted in by membership, S by its group.
    for principal in [Principal(actor: .session(rig.p), group: Self.alice), Principal(actor: .session(rig.s), group: .shared)] {
      let senders = try await rig.space.query("SELECT sender_session_id, sender_grp FROM message_senders ORDER BY n", as: principal).rows
      #expect(senders == [[.text(rig.p.rawValue), .text("alice")], [.text(rig.s.rawValue), .text("shared")]])
    }
    let bystander = try await rig.store.createSession(group: Self.alice, title: "B", kind: .agent, createdBy: "owner", model: .test)
    let unseen = try await rig.space.query("SELECT n FROM message_senders", as: Principal(actor: .session(bystander), group: Self.alice)).rows
    #expect(unseen.isEmpty)
  }

  @Test func aDMFromAliceCanBeAnswered() async throws {
    let rig = try await makeRig()
    let opened = try await rig.store.post(
      .dm(with: rig.s.rawValue), messageID: MessageID("m1"), sender: sender(rig.p), senderSession: rig.p,
      content: .init(text: "ping"),
    )
    #expect(opened.enqueued == [rig.s])
    #expect(try await rig.store.conversation(opened.message.conversation).group == Self.alice)
    let answered = try await rig.store.post(
      .dm(with: rig.p.rawValue), messageID: MessageID("m2"), sender: sender(rig.s), senderSession: rig.s,
      content: .init(text: "pong"),
    )
    #expect(answered.enqueued == [rig.p])
    #expect(answered.message.conversation == opened.message.conversation)
  }

  @Test func anAttachmentLivesInItsConversationsGroupAndEveryRecipientCanNameIt() async throws {
    let rig = try await makeRig()
    let events = Collector<MutationEvent>()
    let stream = await rig.space.observeFS(glob: "/_/conversations/**", group: Self.alice)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    let own = try await rig.store.post(
      .box(rig.p), messageID: MessageID("m1"), sender: Sender(id: "carol", timeZone: Self.utc),
      content: .init(text: "for you"), uploads: [AttachmentUpload(name: "note.txt", bytes: Array("mine".utf8))],
      acting: Principal(actor: .anonymous, group: Self.alice),
    )
    let path = try #require(own.message.content.attachments.first?.path)
    #expect(path.hasPrefix("/_/conversations/\(rig.p.rawValue)/attachments/"))
    #expect(try await rig.space.fs(Self.alice).read(path).1 == Data("mine".utf8))
    await #expect(throws: (any Error).self) { _ = try await rig.space.fs(.shared).read(path) }
    #expect(try await queued(rig, rig.p).last?.content.attachments.first?.path == path)
    let written = await awaitItems(events, atLeast: 1)
    #expect(written.map(\.path) == [path])
    #expect(written.map(\.group) == [Self.alice])

    let dm = try await rig.store.post(
      .dm(with: rig.s.rawValue), messageID: MessageID("m2"), sender: sender(rig.p), senderSession: rig.p,
      content: .init(text: "see"), uploads: [AttachmentUpload(name: "dm.txt", bytes: Array("dm".utf8))],
    )
    let dmPath = try #require(dm.message.content.attachments.first?.path)
    #expect(try await rig.store.conversation(dm.message.conversation).group == Self.alice)
    let heard = try #require(try await queued(rig, rig.s).last?.content.attachments.first?.path)
    #expect(heard == "wuhu://alice.localspace" + dmPath)
    #expect(try await rig.space.attachmentBytes(heard, readingIn: .shared) == Data("dm".utf8))
    #expect(try await rig.store.readsAttachment(dmPath, in: Self.alice, member: rig.s.rawValue))
    let stranger = try await rig.store.createSession(group: .shared, title: "X", kind: .agent, createdBy: "owner", model: .test)
    #expect(try await !rig.store.readsAttachment(dmPath, in: Self.alice, member: stranger.rawValue))
    #expect(try await !rig.store.readsAttachment(dmPath, in: .shared, member: rig.s.rawValue))

    _ = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m3"), sender: sender(rig.p), senderSession: rig.p, content: .init(text: "hi"),
    )
    let reply = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m4"), sender: sender(rig.s), senderSession: rig.s, replyTarget: MessageID("m3"),
      content: .init(text: "look"), uploads: [AttachmentUpload(name: "shared.txt", bytes: Array("shared".utf8))],
    )
    let sharedPath = try #require(reply.message.content.attachments.first?.path)
    #expect(try await rig.space.fs(.shared).read(sharedPath).1 == Data("shared".utf8))
    let seen = try #require(try await queued(rig, rig.p).last?.content.attachments.first?.path)
    #expect(seen == "wuhu://shared.localspace" + sharedPath)
    #expect(try await rig.space.attachmentBytes(seen, readingIn: Self.alice) == Data("shared".utf8))
  }

  @Test func aTopLevelAgentTakesAReadableGroupOnly() async throws {
    let rig = try await makeRig()
    #expect(try await rig.space.homeGroup(nil, creator: Self.alice) == Self.alice)
    #expect(try await rig.space.homeGroup(.shared, creator: Self.alice) == .shared)
    await #expect(throws: SpaceError.groupForbidden(Self.alice.rawValue)) {
      _ = try await rig.space.homeGroup(Self.alice, creator: .shared)
    }
    await #expect(throws: SpaceError.groupForbidden(Self.bob.rawValue)) {
      _ = try await rig.space.homeGroup(Self.bob, creator: Self.alice)
    }
  }

  @Test func layerWritesNeedASharedAdminOnlyInShared() async throws {
    let rig = try await makeRig()
    let child = try await rig.store.createSession(
      group: .shared, title: "t", kind: .task, parent: rig.s, createdBy: rig.s.rawValue, executor: .kernel(.test),
    )
    let agents = try path("/AGENTS.md")
    let skill = try path("/.agents/skills/x/SKILL.md")
    let models = try path("/models.json")
    await #expect(throws: SpaceError.layerForbidden(path: "/AGENTS.md", group: "shared")) {
      try await rig.space.refuseLayerWrite(agents, in: .shared, by: .session(child))
    }
    await #expect(throws: SpaceError.layerForbidden(path: "/models.json", group: "shared")) {
      try await rig.space.refuseLayerWrite(models, in: .shared, by: .session(rig.p))
    }
    try await rig.space.refuseLayerWrite(skill, in: .shared, by: .session(rig.s))
    try await rig.space.refuseLayerWrite(agents, in: Self.alice, by: .session(rig.p))
    try await rig.space.refuseLayerWrite(models, in: Self.alice, by: .session(rig.p))
    await #expect(throws: SpaceError.layerForbidden(path: "/AGENTS.md", group: "alice")) {
      try await rig.space.refuseLayerWrite(agents, in: Self.alice, by: .session(rig.s))
    }
  }

  @Test func theSpaceWideLayerIsListedInFullAndCanBeTurnedOff() async throws {
    let rig = try await makeRig()
    _ = try await rig.space.fs(.shared).write("/AGENTS.md", bytes("Shared rules.\n"), ifMatch: nil)
    _ = try await rig.space.fs(.shared).write("/.agents/skills/deploy/SKILL.md", bytes("---\ndescription: Deploy.\n---\n"), ifMatch: nil)
    _ = try await rig.space.fs(Self.alice).write("/.agents/skills/mine/SKILL.md", bytes("---\ndescription: Mine.\n---\n"), ifMatch: nil)

    let home = try await rig.space.sessionHome(rig.p)
    #expect(home.spaceLayerRendered.contains("from wuhu://shared.localspace/AGENTS.md:\n\nShared rules."))
    #expect(home.spaceLayerRendered.contains("(wuhu://shared.localspace/.agents/skills/deploy/SKILL.md)"))
    #expect(home.groupRendered.contains("Group skills"))
    #expect(home.groupRendered.contains("(/.agents/skills/mine/SKILL.md)"))
    #expect(home.rendered.contains("the system, the space-wide layer, your group's root, then yours"))

    let shared = try await rig.space.sessionHome(rig.s)
    #expect(shared.spaceLayerRendered.isEmpty)
    #expect(shared.groupRendered.contains("(/.agents/skills/deploy/SKILL.md)"))

    try await rig.store.advancePromptRevision(rig.p)
    try await rig.space.writer.write { db in
      try db.execute(sql: "INSERT INTO session_scope_context VALUES (?, 'tc-1', '{}', 'notes')", arguments: [rig.p.rawValue])
      try db.execute(sql: "INSERT INTO session_scope_context VALUES (?, 'tc-1', '{}', 'notes')", arguments: [rig.s.rawValue])
    }
    try await rig.space.setSpaceLayer(Self.alice, on: false)
    let noticed = try await rig.space.writer.read { db in
      try String.fetchAll(db, sql: "SELECT session_id FROM session_scope_context")
    }
    #expect(noticed == [rig.s.rawValue])
    // The frozen prompt keeps the layer until the next compaction or Start over.
    let frozen = try await rig.space.sessionHome(rig.p, at: try await rig.store.promptRevision(rig.p))
    #expect(!frozen.spaceLayerRendered.isEmpty)
    try await rig.store.advancePromptRevision(rig.p)
    let off = try await rig.space.sessionHome(rig.p, at: try await rig.store.promptRevision(rig.p))
    #expect(off.spaceLayerRendered.isEmpty)
    #expect(off.rendered.contains("the system, your group's root, then yours"))
    let fresh = try await rig.store.createSession(group: Self.alice, title: "Q", kind: .agent, createdBy: "owner", model: .test)
    #expect(try await rig.space.sessionHome(fresh, at: try await rig.store.promptRevision(fresh)).spaceLayerRendered.isEmpty)
  }

  @Test func senderAdminIsAboutTheRecipientsGroup() async throws {
    let rig = try await makeRig()
    let m = try await rig.space.addAccount(kind: .human, name: "m", admin: true)
    let person = try await rig.space.addAccount(kind: .human, name: "al")
    let s2 = try await rig.store.createSession(group: .shared, title: "S2", kind: .agent, createdBy: "owner", model: .test)
    let own = try await rig.store.createSession(group: Self.alice, title: "C", kind: .agent, createdBy: rig.p.rawValue, model: .test)

    _ = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m1"), sender: Sender(id: "m", timeZone: Self.utc), content: .init(text: "hi"),
      acting: Principal(actor: .person(persona: "m", account: m.id), group: .shared),
    )
    let fromM = try #require(try await queued(rig, rig.s).last)
    #expect(fromM.senderAdmin == true)
    #expect(fromM.header.render().contains("<sender-admin>yes</sender-admin>"))

    _ = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m2"), sender: Sender(id: "al", timeZone: Self.utc), content: .init(text: "hi"),
      acting: Principal(actor: .person(persona: "al", account: person.id), group: Self.alice),
    )
    let fromAlice = try #require(try await queued(rig, rig.s).last)
    #expect(fromAlice.senderAdmin == false)
    #expect(fromAlice.senderGroup == Self.alice)
    #expect(fromAlice.header.render().contains("<sender-admin>no</sender-admin>"))

    _ = try await rig.store.post(
      .box(s2), messageID: MessageID("m3"), sender: sender(rig.s), senderSession: rig.s, content: .init(text: "hi"),
    )
    #expect(try #require(try await queued(rig, s2).last).senderAdmin == true)

    _ = try await rig.store.post(
      .box(rig.p), messageID: MessageID("m4"), sender: sender(own), senderSession: own, content: .init(text: "hi"),
    )
    let fromOwn = try #require(try await queued(rig, rig.p).last)
    #expect(fromOwn.senderAdmin == true)
    #expect(!fromOwn.header.render().contains("<sender-group>"))
  }

  @Test func watermarksShowOnlyTheReadersOwnRows() async throws {
    let rig = try await makeRig()
    try await rig.space.writer.write { db in
      for identity in [rig.p.rawValue, rig.s.rawValue, "someone"] {
        try db.execute(sql: "INSERT INTO watermarks VALUES (?, ?, 1)", arguments: [identity, rig.s.rawValue])
      }
    }
    let rows = try await rig.space.query("SELECT identity FROM watermarks", as: Principal(actor: .session(rig.s), group: .shared)).rows
    #expect(rows == [[.text(rig.s.rawValue)]])
  }

  @Test func aPersonSeesTheirDMAndItsNotificationsFromAnyGroup() async throws {
    let rig = try await makeRig()
    let bob = try await rig.space.addAccount(kind: .human, name: "bob")
    let persona = try await rig.space.writer.write { db in
      try db.execute(
        sql: "INSERT INTO personas VALUES ('bobp', 900, 'k', ?, '2026-01-01T00:00:00.000Z')", arguments: [bob.id.rawValue],
      )
      return "bobp"
    }
    let dm = try await rig.store.post(
      .dm(with: persona), messageID: MessageID("m1"), sender: sender(rig.p), senderSession: rig.p, content: .init(text: "hi bob"),
    )
    #expect(try await rig.store.conversation(dm.message.conversation).group == Self.alice)
    let asBob = Principal(actor: .person(persona: persona, account: bob.id), group: Self.bob)
    let conversations = try await rig.space.query("SELECT id FROM conversations", as: asBob).rows
    #expect(conversations == [[.text(dm.message.conversation.rawValue)]])
    let notifications = try await rig.space.query("SELECT source FROM notifications", as: asBob).rows
    #expect(notifications.contains([.text(dm.message.conversation.rawValue)]))
    #expect(try await rig.store.conversations(member: persona).map(\.id) == [dm.message.conversation])
  }

  // One inbox across a person's groups: each row names its group, and a
  // conversation message from outside that group names the sender's.
  @Test func aNotificationNamesItsGroupAndAnOutsideSendersGroup() async throws {
    let rig = try await makeRig()
    let account = try await rig.space.addAccount(kind: .human, name: "carol")
    try await rig.space.writer.write { db in
      try db.execute(
        sql: "INSERT INTO personas VALUES ('carol', 901, 'k', ?, '2026-01-01T00:00:00.000Z')", arguments: [account.id.rawValue],
      )
    }
    let carol = Sender(id: "carol", timeZone: Self.utc)
    let dm = try await rig.store.post(
      .dm(with: "carol"), messageID: MessageID("m1"), sender: sender(rig.p), senderSession: rig.p, content: .init(text: "from alice"),
    )
    _ = try await rig.store.post(.box(rig.s), messageID: MessageID("m2"), sender: carol, content: .init(text: "joining"))
    _ = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m3"), sender: sender(rig.p), senderSession: rig.p, content: .init(text: "outsider"),
    )
    _ = try await rig.store.post(
      .box(rig.s), messageID: MessageID("m4"), sender: sender(rig.s), senderSession: rig.s, content: .init(text: "insider"),
    )
    let rows = try await rig.store.notifications(recipient: "carol")
    #expect(rows.map(\.source) == [dm.message.conversation.rawValue, rig.s.rawValue, rig.s.rawValue])
    #expect(rows.map(\.group) == [Self.alice, .shared, .shared])
    let senderGroups = rows.map { row in
      (try? JSONSerialization.jsonObject(with: Data(row.payload.utf8)) as? [String: Any])?["senderGroup"] as? String
    }
    #expect(senderGroups == [nil, "alice", nil])
  }
}
