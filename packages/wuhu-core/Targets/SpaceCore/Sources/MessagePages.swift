import Foundation
import GRDB
import SessionDomain

public enum MessageAnchor: Hashable, Sendable {
  case message(MessageID)
  case time(Date)
}

public enum MessageCursor: Hashable, Sendable {
  case latest
  case after(MessageAnchor)
  case before(MessageAnchor)
}

public struct MessagePage: Hashable, Sendable {
  public var messages: [MessageRecord]
  /// The anchor that continues in the cursor's direction (`before` for `latest`); `nil` when nothing lies further.
  public var next: MessageID?
}

extension SessionStore {
  /// Anchors resolve to the message sequence, so messages sharing a timestamp are never split across pages. A message id
  /// from another conversation is `unknownMessage`.
  public func page(of conversation: ConversationID, from cursor: MessageCursor, limit: Int) async throws -> MessagePage {
    precondition(limit > 0, "a page holds at least one message")
    let key = conversation.rawValue
    return try await writer.read { db in
      guard try Conversations.record(key, in: db) != nil else {
        throw SessionStoreError.unknownConversation(key)
      }
      switch cursor {
      case .latest:
        return .backward(
          try Conversations.fetch(db, where: "conversation_id = ?", arguments: [key], order: "n DESC", limit: limit + 1),
          limit: limit,
        )
      case let .after(anchor):
        let floor = try MessagePages.floor(anchor, in: key, db)
        return .forward(
          try Conversations.fetch(db, where: "conversation_id = ? AND n > ?", arguments: [key, floor], limit: limit + 1),
          limit: limit,
        )
      case let .before(anchor):
        let ceiling = try MessagePages.ceiling(anchor, in: key, db)
        return .backward(
          try Conversations.fetch(
            db, where: "conversation_id = ? AND n < ?", arguments: [key, ceiling], order: "n DESC", limit: limit + 1,
          ),
          limit: limit,
        )
      }
    }
  }

  /// Never mints the DM: `nil` until one of the two has posted to the other.
  public func directMessage(between a: String, and b: String) async throws -> ConversationID? {
    guard a != b else { return nil }
    let id = Conversations.dmID(a, b)
    return try await writer.read { db in
      try Conversations.record(id.rawValue, in: db) == nil ? nil : id
    }
  }
}

extension MessagePage {
  fileprivate static func forward(_ rows: [MessageRecord], limit: Int) -> MessagePage {
    let messages = Array(rows.prefix(limit))
    return MessagePage(messages: messages, next: rows.count > limit ? messages.last?.id : nil)
  }

  fileprivate static func backward(_ rows: [MessageRecord], limit: Int) -> MessagePage {
    let messages = Array(rows.prefix(limit).reversed())
    return MessagePage(messages: messages, next: rows.count > limit ? messages.first?.id : nil)
  }
}

private enum MessagePages {
  // `created_at` rows written before fractional seconds were stored sort wrong as text against newer ones, so time
  // comparisons go through julianday.
  static func floor(_ anchor: MessageAnchor, in conversation: String, _ db: Database) throws -> Int64 {
    switch anchor {
    case let .message(id):
      try sequence(of: id, in: conversation, db)
    case let .time(date):
      try Int64.fetchOne(
        db,
        sql: """
        SELECT MAX(n) FROM messages WHERE conversation_id = ? AND julianday(created_at) <= julianday(?)
        """,
        arguments: [conversation, millisecond(date)],
      ) ?? 0
    }
  }

  static func ceiling(_ anchor: MessageAnchor, in conversation: String, _ db: Database) throws -> Int64 {
    switch anchor {
    case let .message(id):
      try sequence(of: id, in: conversation, db)
    case let .time(date):
      try Int64.fetchOne(
        db,
        sql: """
        SELECT MIN(n) FROM messages WHERE conversation_id = ? AND julianday(created_at) >= julianday(?)
        """,
        arguments: [conversation, millisecond(date)],
      ) ?? .max
    }
  }

  // A time parsed from "…16.326Z" can land a hair under .326 and the format
  // truncates, so round to the millisecond the rows are stored in.
  private static func millisecond(_ date: Date) -> String {
    SQLiteDateFormat.string(from: date.addingTimeInterval(0.0005))
  }

  private static func sequence(of id: MessageID, in conversation: String, _ db: Database) throws -> Int64 {
    guard let n = try Int64.fetchOne(
      db,
      sql: "SELECT n FROM messages WHERE id = ? AND conversation_id = ?",
      arguments: [id.rawValue, conversation],
    ) else {
      throw SessionStoreError.unknownMessage(id.rawValue)
    }
    return n
  }
}
