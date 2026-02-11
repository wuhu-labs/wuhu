import Foundation
import PiAI
import WuhuAPI

enum WuhuGroupChat {
  static let reminderCustomType = "wuhu_group_chat_reminder_v1"

  static func reminderEntryIndex(in transcript: [WuhuSessionEntry]) -> Int? {
    transcript.lastIndex { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .customMessage(c) = m else { return false }
      return c.customType == reminderCustomType
    }
  }

  static func reminderText(previousUser: String) -> String {
    """
    A new user has joined this conversation. From now on, every user message will be prefixed with the user's name.
    Previously, you have been discussing with \(previousUser).
    """
  }

  static func makeReminderMessage(previousUser: String, timestamp: Date = Date()) -> WuhuPersistedMessage {
    .customMessage(.init(
      customType: reminderCustomType,
      content: [.text(text: reminderText(previousUser: previousUser), signature: nil)],
      details: .object([
        "previous_user": .string(previousUser),
        "version": .number(1),
      ]),
      display: true,
      timestamp: timestamp,
    ))
  }

  static func renderPromptInput(user: String, input: String) -> String {
    "\(user):\n\n\(input)"
  }

  static func renderForLLM(
    message: WuhuPersistedMessage,
    entryIndex: Int,
    reminderIndex: Int?,
  ) -> Message? {
    let shouldPrefix = reminderIndex != nil && entryIndex > reminderIndex!

    switch message {
    case let .user(u) where shouldPrefix:
      let prefix = ContentBlock.text(.init(text: "\(u.user):\n\n"))
      let blocks = [prefix] + u.content.map { $0.toPi() }
      return .user(.init(content: blocks, timestamp: u.timestamp))

    default:
      return message.toPiMessage()
    }
  }
}
