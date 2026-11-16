public struct ToolCallID: RawRepresentable, Hashable, Sendable, Codable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
}
