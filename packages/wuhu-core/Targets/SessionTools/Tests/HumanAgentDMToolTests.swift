#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
import Testing

struct HumanAgentDMToolTests {
  private let refusal = "There is no DM between human and agent. If you want to notify a human that has talked in your conversation box, simply post that box, optionally specifying the reply target's message ID."

  @Test func removedUserArgumentIsRefusedRatherThanSilentlyPostingIntoTheBox() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space, name: "a")
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      for user: JSONValue in ["carol", .null] {
        let result = try await world.run("send_message", .object(["message": "lost", "user": user]))
        #expect(try failureMessage(result) == refusal)
      }
      #expect(try await space.sessions.messages(conversation: .init(session.rawValue)).isEmpty)
      #expect(try await space.sessions.conversations(member: "carol").isEmpty)
      let tool = try #require(ToolExecutor.tools.first {
        if case .function("send_message", _, _) = $0 { return true }
        return false
      })
      guard case let .function(_, description, parameters) = tool,
            case let .object(schema) = parameters, case let .object(properties)? = schema["properties"]
      else {
        Issue.record("missing parameter schema")
        return
      }
      #expect(!description.contains("user to DM"))
      #expect(properties["user"] == nil)
    }
  }

  @Test func aPersonPersonDMIdIsAlsoATypedRefusalForASession() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space, name: "a")
      let dm = try await space.sessions.post(
        .dm(with: "dave"), messageID: .init("human-post"), sender: Sender(id: "carol", timeZone: .gmt),
        content: .init(text: "hello"),
      )
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      let result = try await world.run("send_message", .object([
        "message": "lost", "conversation": .string(dm.message.conversation.rawValue),
      ]))
      #expect(try failureMessage(result) == refusal)
      #expect(try await space.sessions.messages(conversation: dm.message.conversation).map(\.content.text) == ["hello"])
      #expect(try await space.sessions.notifications(recipient: "carol").isEmpty)
      #expect(try await space.sessions.notifications(recipient: "dave").count == 1)
      #expect(try await space.sessions.messages(conversation: .init(session.rawValue)).isEmpty)
    }
  }

  @Test func anOldHumanSessionDMIdIsATypedRefusal() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space, name: "a")
      let dm = try await space.sessions.createConversation(members: [session.rawValue, "carol"], in: .shared)
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE conversations SET kind = 'dm_user' WHERE id = ?", arguments: [dm.rawValue])
      }
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      let result = try await world.run("send_message", .object(["message": "lost", "conversation": .string(dm.rawValue)]))
      #expect(try failureMessage(result) == refusal)
      #expect(try await space.sessions.messages(conversation: dm).isEmpty)
      #expect(try await space.sessions.notifications(recipient: "carol").isEmpty)
    }
  }
}
