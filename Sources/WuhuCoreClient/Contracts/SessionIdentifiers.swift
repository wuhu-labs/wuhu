import Foundation

/// Identifier for a long-lived agent session.
public struct SessionID: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifier for a transcript entry.
public struct TranscriptEntryID: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifier for a queued input item (steer/follow-up/system-urgent).
public struct QueueItemID: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Opaque cursor for transcript pagination and catch-up (`?after=...`).
public struct TranscriptCursor: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Opaque cursor for queue journal catch-up (`?steerQueueSince=...`).
public struct QueueCursor: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
