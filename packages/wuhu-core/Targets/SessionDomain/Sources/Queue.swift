import Foundation

public enum QueueInput: Hashable, Sendable, Codable {
  case message(ConversationMessage)
  case notification(SystemNotification)

  public var id: UUID {
    switch self {
    case let .message(message): message.id
    case let .notification(notification): notification.id
    }
  }

  public var transcriptItem: TranscriptItem {
    switch self {
    case let .message(message): .message(message)
    case let .notification(notification): .notification(notification)
    }
  }
}

extension QueueInput {
  // The one cut every input gets on its way into a session, whatever sent it:
  // a message, a script update or result, an observation, a timer.
  public func capped(limit: Int = ToolOutput.backstopBytes) -> QueueInput {
    switch self {
    case var .message(message):
      message.content.text = ToolOutput.backstopped(message.content.text, naming: "message", limit: limit)
      return .message(message)
    case var .notification(notification):
      notification.content.text = ToolOutput.backstopped(notification.content.text, naming: "notification", limit: limit)
      return .notification(notification)
    }
  }
}
