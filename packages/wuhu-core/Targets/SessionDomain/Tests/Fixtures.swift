#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import WuhuAI

enum Fix {
  static let utc = TimeZone(identifier: "UTC")!
  static let tokyo = TimeZone(secondsFromGMT: 9 * 3600)!
  static let instant = Date(timeIntervalSince1970: 1_767_225_600)
  static let session = SessionID("s-1")

  static func message(
    id: String? = nil,
    conversation: String = "ch1",
    kind: MessageKind = .message,
    request: String? = nil,
    sender: String = "alice",
    senderSession: String? = nil,
    replyTarget: String? = nil,
    owesReply: Bool = true,
    text: String = "hello",
    at: Date = instant,
    attachments: [Attachment] = [],
    device: String? = nil,
    viewing: String? = nil,
  ) -> TranscriptItem {
    .message(.init(
      id: UUID(),
      messageID: .init(id ?? "m-\(conversation)-\(sender)"),
      conversationID: .init(conversation),
      sender: .init(id: sender, timeZone: tokyo, device: device),
      senderSession: senderSession.map { SessionID($0) },
      timestamp: at,
      kind: kind,
      requestID: request.map { RequestID($0) },
      replyTarget: replyTarget.map { MessageID($0) },
      owesReply: owesReply,
      viewing: viewing,
      content: .init(text: text, attachments: attachments),
    ))
  }

  static func notification(
    kind: SystemNotification.Kind = .timer,
    subscription: String = "sub-1",
    endsSubscription: Bool = false,
    text: String = "tick",
  ) -> TranscriptItem {
    .notification(.init(
      id: UUID(),
      timestamp: instant,
      kind: kind,
      subscriptionID: .init(subscription),
      endsSubscription: endsSubscription,
      content: .init(text: text),
    ))
  }

  static func context(_ folders: [String: String?], text: String = "") -> TranscriptItem {
    .notification(ScopeContext(folders: folders, text: text).notice(id: UUID(), at: instant))
  }

  static func result(
    _ payload: ToolResultPayload,
    provenance: ToolResultItem.Provenance = .toolCall(.init("call-1")),
  ) -> TranscriptItem {
    .toolResult(.init(id: UUID(), timestamp: instant, provenance: provenance, payload: payload))
  }

  static func assistant(
    text: String = "ok",
    totalTokens: Int,
    toolCalls: [ToolCall] = [],
  ) -> TranscriptItem {
    .assistant(.init(
      id: UUID(),
      timestamp: instant,
      content: [.text(text)] + toolCalls.map { ContentBlock.toolCall($0) },
      stopReason: .stop,
      usage: .init(inputTokens: 0, outputTokens: 0, totalTokens: totalTokens),
      toolCallIDs: [:],
    ))
  }
}
