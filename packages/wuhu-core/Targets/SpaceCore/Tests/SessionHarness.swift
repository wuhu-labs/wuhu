import Dependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import WuhuAI

func withSessionDeps<T>(_ body: () async throws -> T) async rethrows -> T {
  try await withDependencies({
    $0.uuid = .incrementing
    $0.date = .constant(fixedDate)
  }, operation: body)
}

enum SessionFix {
  static let sender = Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!)

  static func message(
    _ text: String = "hello",
    message: String = "m1",
    conversation: String = "ch1",
    owesReply: Bool = false,
    id: UUID = UUID(),
  ) -> QueueInput {
    .message(.init(
      id: id,
      messageID: .init(message),
      conversationID: .init(conversation),
      sender: sender,
      timestamp: fixedDate,
      owesReply: owesReply,
      content: .init(text: text),
    ))
  }

  static func notification(_ text: String = "tick", id: UUID = UUID()) -> QueueInput {
    .notification(.init(
      id: id,
      timestamp: fixedDate,
      kind: .timer,
      subscriptionID: .init("sub-1"),
      content: .init(text: text),
    ))
  }

  static func toolResult(callID: String, id: UUID = UUID()) -> ToolResultItem {
    .init(id: id, timestamp: fixedDate, provenance: .toolCall(.init(callID)), payload: .grep(.init(output: "hit")))
  }

  static func assistant(_ text: String = "ok", toolCalls: [ToolCall] = []) -> AssistantMessage {
    .init(content: [.text(text)] + toolCalls.map { .toolCall($0) })
  }

  static let metadata = AssistantMessageMetadata(
    stopReason: .stop,
    usage: .init(inputTokens: 5, outputTokens: 5, totalTokens: 100),
  )
}

extension ModelSpecifier {
  static let test = ModelSpecifier(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")
}
