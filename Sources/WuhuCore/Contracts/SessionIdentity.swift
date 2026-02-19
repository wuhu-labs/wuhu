import Foundation

/// Who authored an entry or command.
public enum Author: Sendable, Hashable, Codable {
  /// A known system/runtime identity.
  case system

  /// A human or bot participant in a session.
  case participant(ParticipantID, kind: ParticipantKind)

  /// Caller did not provide an author, or the server could not resolve it.
  case unknown
}

public struct ParticipantID: RawRepresentable, Sendable, Hashable, Codable {
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum ParticipantKind: String, Sendable, Hashable, Codable {
  case human
  case bot
}
