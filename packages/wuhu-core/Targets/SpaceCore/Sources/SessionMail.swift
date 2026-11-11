#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import Wuwei

/// An input on its way to a session's queue. One on a `topic` replaces the one on it the model has not seen. It is due at `due`; with a `throttle` instead, no sooner than that long after the model last saw the topic, and a replaced input's time is kept; otherwise at once.
public struct SessionPut: Hashable, Codable, Sendable {
  public var input: QueueInput
  public var topic: String?
  public var due: Date?
  public var throttle: Double?

  public init(_ input: QueueInput, topic: String? = nil, due: Date? = nil, throttle: Double? = nil) {
    self.input = input
    self.topic = topic
    self.due = due
    self.throttle = throttle
  }
}

/// What main mails a session's cell from its own transactions: the cell's messages of the same names, which must decode these.
public enum SessionMail: Hashable, Codable, Sendable {
  /// The session cell's kind.
  public static let kind = "SessionCell"

  case put(SessionPut)
  /// Takes back the input on the topic that the model has not seen.
  case clear(String)
}

extension Sessions {
  /// Main's side of an input: mail to the session's cell, durable with the write in `db`. The cell queues it; whoever commits pokes the cell (`signals.post`), or the worker's scan finds the mail.
  static func enqueue(_ key: String, input: QueueInput, topic: String? = nil, due: Date? = nil, throttle: Double? = nil, nowDate: Date, in db: GRDB.Database) throws {
    if case let .archived(graceExpiresAt) = try record(key, in: db).lifecycle, nowDate >= graceExpiresAt {
      throw SessionStoreError.archiveGraceExpired(key)
    }
    try post(.put(SessionPut(input, topic: topic, due: due, throttle: throttle)), to: key, in: db)
  }

  static func clear(_ key: String, topic: String, in db: GRDB.Database) throws {
    try post(.clear(topic), to: key, in: db)
  }

  static func post(_ mail: SessionMail, to key: String, in db: GRDB.Database) throws {
    try Recipient<SessionMail>(kind: SessionMail.kind, key: key).post(mail, on: db.sqliteConnection!)
  }
}

extension SessionRows {
  public func put(_ id: SessionID, _ put: SessionPut) throws {
    try Sessions.insertInput(id.rawValue, put, nowDate: store.dateGen.now, in: db)
  }

  public func clear(_ id: SessionID, topic: String) throws {
    try Sessions.removeInput(id.rawValue, topic: topic, in: db)
  }
}
