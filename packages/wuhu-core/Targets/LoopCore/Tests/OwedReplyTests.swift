import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct OwedReplyTests {
  @Test func `a settle that owes a reply is nagged into answering, exactly once`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let nagSeen = Box<[SystemNotification]>([])
      let script = InferenceScript([
        Fix.replying("thinking out loud"),
        { request in
          nagSeen.withLock { $0 = request.transcript.owedReplyReminders }
          return Fix.reply("on it", calls: [ToolCall(id: "c-1", name: "send_message", arguments: .object([:]))])
        },
        Fix.replying("all done"),
      ])
      let config = makeConfig(
        executeTool: { call in
          guard call.name == "send_message" else { throw UnexpectedCall("executeTool(\(call.name))") }
          let delivery = try await sessions.post(
            .box(sid),
            messageID: .init("a1"),
            sender: Sender(id: sid.rawValue, timeZone: TimeZone(identifier: "UTC")!),
            senderSession: sid,
            content: .init(text: "answered"),
          )
          return .sendMessage(.init(
            messageID: delivery.message.id,
            conversationID: delivery.message.conversation,
            n: delivery.message.n,
          ))
        },
        inference: { try await script($0) },
      )

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(
          item: Fix.message("please review", conversation: sid.rawValue, owesReply: true),
          to: sid,
        )
        // At least: the whole exchange may run on to the wrap-up between polls.
        try await until("the settle's own reminder reaches the model") { script.count >= 2 }
        try await until("the exchange settles") { try await sessions.settledWork(sid) }
        try await holds("the wrap-up to be the last word") { script.count == 3 }
      }

      #expect(nagSeen.value.count == 1, "the reminder rode the second request with no further delivery")
      #expect(nagSeen.value.first?.conversations == [ConversationID(sid.rawValue)])
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.owedReplyReminders.count == 1, "a standing owe is reminded once")
    }
  }
}
