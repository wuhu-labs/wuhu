#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

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
