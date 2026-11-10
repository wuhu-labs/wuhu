#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID

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
  public func conversation(_ id: ConversationID) async throws -> ConversationRecord {
    guard let record = cell(id).record() else { throw SessionStoreError.unknownConversation(id.rawValue) }
    return record
  }

  public func messages(conversation: ConversationID, after n: Int64 = 0, limit: Int? = nil) async throws -> [MessageRecord] {
    try cell(conversation).messages(after: n, limit: limit)
  }

  public func messagesTail(conversation: ConversationID, before n: Int64? = nil, limit: Int) async throws -> [MessageRecord] {
    try cell(conversation).tail(before: n, limit: limit)
  }

  public func page(of conversation: ConversationID, from cursor: MessageCursor, limit: Int) async throws -> MessagePage {
    try cell(conversation).page(from: cursor, limit: limit)
  }

  /// Never mints the DM: `nil` until one of the two has posted to the other.
  public func directMessage(between a: String, and b: String) async throws -> ConversationID? {
    guard a != b else { return nil }
    let id = Conversations.dmID(a, b)
    return cell(id).record() == nil ? nil : id
  }

  /// Whether a session id, a persona, or nil (the --dev seat) acting in `group` reads the conversation.
  public func reads(_ conversation: ConversationRecord, reader: String?, group: GroupID) async throws -> Bool {
    cell(conversation.id).reads(conversation, reader: reader, group: group)
  }

  private func cell(_ id: ConversationID) -> ConversationCell {
    runtime.worker().cell(ConversationCell.ID(id.rawValue))
  }
}
