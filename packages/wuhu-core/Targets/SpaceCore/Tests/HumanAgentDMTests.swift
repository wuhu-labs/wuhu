#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct HumanAgentDMTests {
  @Test func openingAHumanSessionDMIsRefusedForAgentsAndTasksFromEitherSide() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
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
      let store = try Space.inMemory().sessions
      let delivery = try await store.post(.dm(with: "dave"), messageID: .init("m1"), sender: Sender(id: "carol", timeZone: .gmt), content: .init(text: "hi"))
      #expect(delivery.enqueued.isEmpty)
      #expect(try await store.conversation(delivery.message.conversation).members.allSatisfy { $0.kind == .user })
      #expect(try await store.notifications(recipient: "dave").count == 1)
    }
  }
}
