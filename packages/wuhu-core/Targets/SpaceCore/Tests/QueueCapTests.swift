import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

struct QueueCapTests {
  private func stored(_ input: QueueInput) async throws -> QueueInput {
    let store = try makeSpace().sessions
    let sid = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
    _ = try await store.enqueue(sid, input: input)
    return try #require(try await store.hydrate(sid).undrained.first).input
  }

  private func text(_ input: QueueInput) -> String {
    switch input {
    case let .message(message): message.content.text
    case let .notification(notification): notification.content.text
    }
  }

  @Test func aNotificationPastTheBackstopIsCutWhenQueued() async throws {
    try await withSessionDeps {
      let big = String(repeating: "x", count: 1 << 20)
      let queued = text(try await stored(SessionFix.notification(big)))
      #expect(queued.utf8.count < ToolOutput.backstopBytes + 200)
      #expect(queued.hasPrefix(String(repeating: "x", count: 1000)))
      #expect(queued.contains("[kernel backstop: notification was \(1 << 20) bytes; showing the first"))
    }
  }

  @Test func aMessagePastTheBackstopIsCutWhenQueued() async throws {
    try await withSessionDeps {
      let queued = text(try await stored(SessionFix.message(String(repeating: "y", count: 200_000))))
      #expect(queued.contains("[kernel backstop: message was 200000 bytes; showing the first"))
    }
  }

  @Test func inputsWithinTheBackstopAreStoredWhole() async throws {
    try await withSessionDeps {
      let small = String(repeating: "z", count: ToolOutput.backstopBytes)
      let queued = try await stored(SessionFix.notification(small))
      #expect(text(queued) == small)
    }
  }
}
