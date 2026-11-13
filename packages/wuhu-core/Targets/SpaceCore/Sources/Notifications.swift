#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import Wuwei

public enum NotificationKind: String, Hashable, Sendable, Codable {
  case conversationMessage = "conversation_message"
  case sessionSettled = "session_settled"
  case sessionErrored = "session_errored"
  case sessionDisconnected = "session_disconnected"
  case contractorDisconnected = "contractor_disconnected"
}

public struct NotificationRecord: Hashable, Sendable {
  public var n: Int64
  public var recipient: String
  public var source: String
  public var kind: NotificationKind
  public var payload: String
  public var createdAt: Date
  /// The group the notification belongs to: a conversation's, or the
  /// session's. A person reads one inbox across every group.
  public var group: GroupID

  init(row: NotificationRow) {
    n = row.n
    recipient = row.recipient
    source = row.source
    kind = NotificationKind(rawValue: row.kind)!
    payload = row.payload
    createdAt = try! SQLiteDateFormat.date(from: row.createdAt)
    group = GroupID(rawValue: row.group)
  }
}

enum Notifications {
  struct ConversationPayload: Codable {
    var messageID: String
    var conversationID: String
    var sender: String
    /// The poster's group, set only when it isn't the conversation's: an
    /// outside sender.
    var senderGroup: String?
    var text: String
  }

  struct ErroredPayload: Codable {
    var sessionID: String
    var error: String
    var message: String?
  }

  static func conversationPayload(
    messageID: MessageID,
    conversation: ConversationID,
    sender: String,
    senderGroup: GroupID? = nil,
    text: String,
  ) throws -> String {
    try Sessions.encode(ConversationPayload(
      messageID: messageID.rawValue,
      conversationID: conversation.rawValue,
      sender: sender,
      senderGroup: senderGroup?.rawValue,
      text: text,
    ))
  }

  // The distinguished owner principal (SpaceContract's ownerIdentity on the
  // wire).
  static let ownerRecipient = "owner"

  static func fireErrored(_ key: String, error: String, said: String?, now: String, in db: GRDB.Database) throws {
    let payload = try Sessions.encode(ErroredPayload(
      sessionID: key,
      error: error,
      message: said,
    ))
    let note = PersonNote(source: key, group: try Sessions.group(of: key, in: db), kind: .sessionErrored, payload: payload, createdAt: now)
    try PersonCell.ID(ownerRecipient).recipient.post(.notify(ownerRecipient, note), on: db.sqliteConnection!)
  }
}

extension SessionStore {
  public func notifications(recipient: String, after n: Int64 = 0) -> [NotificationRecord] {
    let worker = runtime.worker()
    guard let person = worker.cell(SpaceCell.ID("space")).personCell(recipient) else { return [] }
    return worker.cell(person).notifications(after: n)
  }

  @discardableResult
  public func advanceWatermark(identity: String, source: String) async throws -> Int64 {
    let worker = runtime.worker()
    guard let person = worker.cell(SpaceCell.ID("space")).personCell(identity) else { throw SpaceError.notFound(identity) }
    return try await worker.call(person) { try $0.read(identity, source: source) }
  }
}
