import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct OwedReplyTests {
  @Test func `a settle that owes a reply is nagged into answering, exactly once`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let nagSeen = Box<[TranscriptLine]>([])
      let script = InferenceScript([
        Fix.replying("thinking out loud"),
        { request in
          nagSeen.withLock { $0 = request.lines.owedReplyReminders }
          return Fix.reply("on it", calls: [ToolCall(id: "c-1", name: "send_message", arguments: .object([:]))])
        },
        Fix.replying("all done"),
      ])
      let config = makeConfig(
        executeInvocation: { invocation in
          let call = invocation.call
          let sid = invocation.sessionID
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

      let service = SessionExecution(space: space, loopConfig: config)
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(
          item: Fix.message("please review", conversation: sid.rawValue, owesReply: true),
          to: sid,
        )
        try await until("the settle's own reminder reaches the model") { script.count >= 2 }
        try await until("the exchange settles") { try await sessions.settledWork(sid) }
        try await holds("the wrap-up to be the last word") { script.count == 3 }
      }

      #expect(nagSeen.value.count == 1, "the reminder rode the second request with no further delivery")
      #expect(nagSeen.value.first?.role == .user)
      #expect(nagSeen.value.first?.text.hasSuffix("\n\n" + SessionPrompt.owedReply(conversations: [sid.rawValue])) == true)
      let lines = try await sessions.lines(sid)
      #expect(lines.owedReplyReminders.count == 1, "a standing owe is reminded once")
    }
  }
}
