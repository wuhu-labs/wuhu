import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct HumanAgentDMTests {
  @Test func personAliasesAndCanonicalIDsOpenOneDMAndUnknownPeopleAreRefused() async throws {
    let space = try Space.inMemory()
    try await space.registerPeople(["alice-id", "bob-id"])
    _ = try await space.setUserProfile(principal: "bob-id", handle: "bob", displayName: nil)
    _ = try await space.setUserProfile(principal: "bob-id", handle: "renamed", displayName: nil)
    let first = try await space.sessions.post(.dm(with: "BOB"), messageID: .init("one"), sender: Sender(id: "alice-id", timeZone: .gmt), content: .init(text: "hello"))
    let second = try await space.sessions.post(.dm(with: "renamed"), messageID: .init("two"), sender: Sender(id: "alice-id", timeZone: .gmt), content: .init(text: "again"))
    let reply = try await space.sessions.post(.dm(with: "alice-id"), messageID: .init("three"), sender: Sender(id: "bob-id", timeZone: .gmt), content: .init(text: "reply"))
    #expect(first.message.conversation == second.message.conversation)
    #expect(first.message.conversation == reply.message.conversation)
    #expect(try await space.sessions.conversation(first.message.conversation).members.map(\.member) == ["alice-id", "bob-id"])
    await #expect(throws: SessionStoreError.unknownPerson("missing")) {
      try await space.sessions.post(.dm(with: "missing"), messageID: .init("unknown"), sender: Sender(id: "alice-id", timeZone: .gmt), content: .init(text: "no"))
    }
    await #expect(throws: SessionStoreError.selfDirectMessage("bob-id")) {
      try await space.sessions.post(.dm(with: "BOB"), messageID: .init("self"), sender: Sender(id: "bob-id", timeZone: .gmt), content: .init(text: "no"))
    }
  }

  @Test func unenrolledDevSeatCanOpenAPersonDM() async throws {
    let space = try Space.inMemory()
    try await space.registerPeople(["bob-id"])
    _ = try await space.setUserProfile(principal: "bob-id", handle: "bob", displayName: nil)
    let delivery = try await space.sessions.post(.dm(with: "BOB"), messageID: .init("dev-dm"), sender: Sender(id: "owner", timeZone: .gmt), content: .init(text: "hello"))
    #expect(try await space.sessions.conversation(delivery.message.conversation).members.map(\.member).sorted() == ["bob-id", "owner"])
    #expect(try await space.sessions.reads(space.sessions.conversation(delivery.message.conversation), reader: "owner", group: .shared))
  }

  @Test func openingAHumanSessionDMIsRefusedForAgentsAndTasksFromEitherSide() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      try await space.registerPeople(["carol", "dave"])
      let store = space.sessions
      let agent = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "carol", model: .test)
      let task = try await store.createSession(group: .shared, title: "t", kind: .task, parent: agent, createdBy: agent.rawValue, executor: .kernel(.test))
      for session in [agent, task] {
        for bySession in [true, false] {
          let id = MessageID("\(session.rawValue)-\(bySession)")
          await #expect(throws: SessionStoreError.humanAgentDirectMessage) {
            _ = try await store.post(
              .dm(with: bySession ? "carol" : session.rawValue), messageID: id,
              sender: Sender(id: bySession ? session.rawValue : "carol", timeZone: .gmt),
              senderSession: bySession ? session : nil, content: .init(text: "not delivered"),
            )
          }
          #expect(try await store.message(id) == nil)
        }
        #expect(try await store.hydrate(session).undrained.isEmpty)
      }
      #expect(try await store.conversations(member: "carol").isEmpty)
      #expect(try await store.notifications(recipient: "carol").isEmpty)
    }
  }

  @Test func oldHumanSessionDMsRemainReadableButNeitherSideCanPost() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      try await space.registerPeople(["carol", "dave"])
      let store = space.sessions
      let agent = try await store.createSession(group: .shared, title: "a", kind: .agent, createdBy: "carol", model: .test)
      let dm = try await space.writer.write { db in
        let id = try Conversations.resolveDM("carol", agent.rawValue, group: .shared, now: "2026-01-01T00:00:00.000Z", in: db)
        try db.execute(
          sql: "INSERT INTO messages (id, conversation_id, sender_id, sender_timezone, kind, content, created_at) VALUES ('old', ?, 'carol', 'GMT', 'message', ?, '2026-01-01T00:00:00.000Z')",
          arguments: [id.rawValue, try Sessions.encode(MessageContent(text: "history"))],
        )
        return id
      }
      for (bySession, messageID) in [(true, "new-agent"), (false, "new-person"), (true, "old"), (false, "old")] {
        await #expect(throws: SessionStoreError.humanAgentDirectMessage) {
          _ = try await store.post(
            .conversation(dm), messageID: MessageID(messageID),
            sender: Sender(id: bySession ? agent.rawValue : "carol", timeZone: .gmt),
            senderSession: bySession ? agent : nil, content: .init(text: "not delivered"),
          )
        }
      }
      #expect(try await store.reads(store.conversation(dm), reader: "carol", group: .shared))
      #expect(try await store.messages(conversation: dm).map(\.content.text) == ["history"])
      #expect(try await space.query("SELECT id FROM messages").rows == [[.text("old")]])
      #expect(try await store.hydrate(agent).undrained.isEmpty)
      #expect(try await store.notifications(recipient: "carol").isEmpty)
    }
  }

  @Test func humanHumanDMsStillPostAndNotify() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      try await space.registerPeople(["carol", "dave"])
      let store = space.sessions
      let delivery = try await store.post(.dm(with: "dave"), messageID: .init("m1"), sender: Sender(id: "carol", timeZone: .gmt), content: .init(text: "hi"))
      #expect(delivery.enqueued.isEmpty)
      #expect(try await store.conversation(delivery.message.conversation).members.allSatisfy { $0.kind == .user })
      #expect(try await store.notifications(recipient: "dave").count == 1)
    }
  }
}
