#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import GRDB
import JSONValue
import SessionDomain
import SessionTools
import struct SpaceContract.ConversationPostOutput
@testable import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolCall

@Suite struct HumanAgentDMRouteTests {
  private let refusal = "There is no DM between human and agent. If you want to notify a human that has talked in your conversation box, simply post that box, optionally specifying the reply target's message ID."

  @Test func sessionHTTPUserAndLegacyConversationTargetsAreRefused() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.mintPersona()
      let dm = try await legacyDM(t.harness, session: t.parent, person: person)
      for body: JSONValue in [
        ["message": "lost", "user": .string(person)],
        ["message": "lost", "user": .null],
        ["message": "lost", "conversation": .string(dm.rawValue)],
      ] {
        let response = try await t.harness.post("/v1/conversation/message", body, bearer: t.token)
        #expect(response.status == .unprocessableContent)
        let fields = try await response.json(JSONValue.self)
        #expect(fields == .object(["code": "refused", "message": .string(refusal)]))
      }
      #expect(try await t.harness.store.messages(conversation: dm).isEmpty)
      #expect(try await t.harness.store.messages(conversation: .init(t.parent.rawValue)).isEmpty)
      #expect(try await t.harness.store.notifications(recipient: person).isEmpty)
    }
  }

  @Test func aSessionCannotPostIntoAPersonPersonDMByIdButPeopleStillCan() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let first = try await t.harness.mintPersona()
      let second = try await t.harness.mintPersona()
      let dm = try await t.harness.call("/v1/conversation/message", [
        "user": .string(second), "identity": .string(first), "message": "hello",
      ], as: ConversationPostOutput.self)
      let response = try await t.harness.post("/v1/conversation/message", [
        "conversation": .string(dm.conversationId), "message": "lost",
      ], bearer: t.token)
      #expect(response.status == .unprocessableContent)
      #expect(try await response.json(JSONValue.self) == .object(["code": "refused", "message": .string(refusal)]))
      #expect(try await t.harness.store.messages(conversation: .init(dm.conversationId)).map(\.content.text) == ["hello"])
      #expect(try await t.harness.store.notifications(recipient: first).isEmpty)
      #expect(try await t.harness.store.notifications(recipient: second).count == 1)
      let reply = try await t.harness.call("/v1/conversation/message", [
        "conversation": .string(dm.conversationId), "identity": .string(second), "message": "answer",
      ], as: ConversationPostOutput.self)
      #expect(reply.conversationId == dm.conversationId)
      #expect(try await t.harness.store.notifications(recipient: first).count == 1)
    }
  }

  @Test func aPersonCannotPostIntoAnOldHumanSessionDMButCanStillReadIt() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.mintPersona()
      let dm = try await legacyDM(t.harness, session: t.parent, person: person)
      let response = try await t.harness.post("/v1/conversation/message", [
        "message": "lost", "conversation": .string(dm.rawValue), "identity": .string(person),
      ])
      #expect(response.status == .forbidden)
      #expect(try await response.json(JSONValue.self) == .object(["code": "humanAgentDM", "message": .string(refusal)]))
      #expect(try await t.harness.get("/v1/conversation/\(dm.rawValue)/messages", query: ["identity": person]).status == .ok)
      #expect(try await t.harness.store.messages(conversation: dm).isEmpty)
      #expect(try await t.harness.store.hydrate(t.parent).undrained.isEmpty)
    }
  }

  @Test func scriptHTTPPostsUseTheSameRefusal() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.mintPersona()
      let scripts = Scripts(space: t.harness.space, identityFetch: { request, session, _ in
        #expect(session == t.parent)
        var request = request
        request.headers[.authorization] = "Bearer " + t.token
        return try await t.harness.api(request)
      })
      let executor = ToolExecutor(space: t.harness.space, scripts: scripts)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripts.run() }
        defer { group.cancelAll() }
        for user in ["'\(person)'", "null"] {
          let source = """
          const response = await fetch('http://space/v1/conversation/message', {
            method: 'POST', identity: true, headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ user: \(user), message: 'lost' })
          });
          result({ status: response.status, body: await response.json() });
          """
          let payload = try await executor.execute(
            session: t.parent,
            call: ToolCall(id: "script-post-\(user)", name: "run_script", arguments: .object(["source": .string(source), "timeout_seconds": 10, "on_timeout": "kill"])),
            state: ToolExecutionState(),
          )
          guard case let .script(result) = payload else {
            Issue.record("unexpected script result: \(payload)")
            return
          }
          #expect(JSONValue.parse(String(result.output.prefix { $0 != "\n" })) == .object([
            "status": 422, "body": .object(["code": "refused", "message": .string(refusal)]),
          ]))
        }
      }
      #expect(try await t.harness.store.conversations(member: person).isEmpty)
      #expect(try await t.harness.store.messages(conversation: .init(t.parent.rawValue)).isEmpty)
    }
  }

  @Test func aBoxReplyStillNotifiesThePersonWhoPostedThere() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let person = try await t.harness.mintPersona()
      let first = try await t.harness.call("/v1/conversation/message", [
        "session": .string(t.parent.rawValue), "identity": .string(person), "message": "hello",
      ], as: ConversationPostOutput.self)
      let reply = try await t.harness.call("/v1/conversation/message", [
        "conversation": .string(t.parent.rawValue), "replyTarget": .string(first.messageId), "message": "answer",
      ], as: ConversationPostOutput.self, bearer: t.token)
      #expect(reply.conversationId == t.parent.rawValue)
      let notifications = try await t.harness.store.notifications(recipient: person)
      #expect(notifications.count == 1)
      #expect(notifications.first?.source == t.parent.rawValue)
      #expect(notifications.first?.payload.contains("answer") == true)
    }
  }

  private func legacyDM(_ harness: SessionHarness, session: SessionID, person: String) async throws -> ConversationID {
    let dm = try await harness.store.createConversation(members: [session.rawValue, person], in: .shared)
    try await harness.space.writer.write { db in
      try db.execute(sql: "UPDATE conversations SET kind = 'dm_user' WHERE id = ?", arguments: [dm.rawValue])
    }
    return dm
  }
}
