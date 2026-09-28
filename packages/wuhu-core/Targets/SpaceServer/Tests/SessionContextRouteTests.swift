import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing

private func context(_ harness: SessionHarness, _ id: String) async throws -> SessionContext? {
  try JSONValueDecoder().decode(
    SessionContextOutput.self,
    from: try await json(try await harness.get("/v1/session/\(id)/context")),
  ).context
}

@Suite struct SessionContextRouteTests {
  @Test func aKernelSessionReportsAnEstimatedContext() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let empty = try #require(try await context(harness, id.rawValue))
      #expect(empty.source == .estimate)
      #expect(empty.usedTokens == 0)
      #expect(empty.maxTokens == 99000, "maxInput minus maxOutput from the space's models document")
      #expect(empty.updatedAt == nil)

      _ = try await harness.store.enqueue(
        id,
        input: .message(ConversationMessage(
          id: UUID(),
          messageID: MessageID(UUID().uuidString),
          conversationID: ConversationID("ch1"),
          sender: Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!),
          timestamp: Date(), content: MessageContent(text: String(repeating: "token ", count: 400)),
        )),
      )
      _ = try await harness.store.drainQueue(id)
      let filled = try #require(try await context(harness, id.rawValue))
      #expect(filled.usedTokens > 0)
      #expect(filled.percentage > 0)
    }
  }

  @Test func anUnknownSessionHasNoContext() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      #expect(try await harness.get("/v1/session/nope/context").status == .notFound)
    }
  }
}
