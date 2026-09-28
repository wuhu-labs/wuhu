public struct SessionID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }

  public var homePath: String { "/_/sessions/\(rawValue)" }
}

public struct ConversationID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct MessageID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct RequestID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SubscriptionID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct ToolCallID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
