/// A valid direct child name inside a virtual filesystem.
///
/// A child name is one path component, not a relative path. Empty names, `.`,
/// `..`, and names containing slash separators are rejected at construction.
public struct VFSPathComponent: RawRepresentable, Sendable, Hashable, Codable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  internal static func require(_ name: String) throws {
    guard Self.isValid(name) else {
      throw VFSNodeError.forbidden
    }
  }

  private static func isValid(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != ".." else { return false }
    guard !name.contains("/"), !name.contains("\\") else { return false }
    return true
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let value = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid VFS child name: \(rawValue)")
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
