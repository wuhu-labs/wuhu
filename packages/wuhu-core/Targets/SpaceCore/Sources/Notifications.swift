import Foundation
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

  /// Reads a row that selected the notification's columns, as the push outboxes do.
  init(row: GRDB.Row) throws {
    self.n = row["n"]
    self.recipient = row["recipient"]
    self.source = row["source"]
    self.kind = NotificationKind(rawValue: row["kind"])!
    self.payload = row["payload"]
    self.createdAt = try SQLiteDateFormat.date(from: row["created_at"])
    self.group = GroupID(rawValue: row["grp"])
  }

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

  /// Mail to the person's cell, durable with the write in `db`; whoever commits pokes the cell (`SpaceRuntime.poke(person:)`), or the worker's scan finds the mail.
  static func notify(_ recipient: String, _ note: PersonNote, in db: GRDB.Database) throws {
    try PersonCell.ID(recipient).recipient.post(.notify(note), on: db.sqliteConnection!)
  }

  // The distinguished owner principal (SpaceContract's ownerIdentity on the
  // wire).
  static let ownerRecipient = "owner"

  static func fireErrored(_ key: String, error: String, transcript: Transcript, now: String, in db: GRDB.Database) throws {
    let payload = try Sessions.encode(ErroredPayload(
      sessionID: key,
      error: error,
      message: transcript.finalAssistantText,
    ))
    try notify(
      ownerRecipient, PersonNote(source: key, group: Sessions.group(of: key, in: db), kind: .sessionErrored, payload: payload, createdAt: now), in: db,
    )
  }
}

extension Transcript {
  var finalAssistantText: String? {
    for item in items.reversed() {
      guard case let .assistant(entry) = item else { continue }
      let texts = entry.content.compactMap { block -> String? in
        guard case let .text(text) = block else { return nil }
        return text.text
      }
      return texts.joined(separator: "\n")
    }
    return nil
  }
}

extension SessionStore {
  public func notifications(recipient: String, after n: Int64 = 0) -> [NotificationRecord] {
    runtime.worker().cell(PersonCell.ID(recipient)).notifications(after: n)
  }

  @discardableResult
  public func advanceWatermark(identity: String, source: String) async throws -> Int64 {
    try await runtime.worker().call(PersonCell.ID(identity)) { try $0.read(source) }
  }
}
