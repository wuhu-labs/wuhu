import JSONValue

public struct MachineID: Codable, Equatable, Hashable, Sendable {
  public static let prefix: String = "mc_"
  public static let suffixLength: Int = 8

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }

  public static var jsonSchema: JSONValue {
    .object(["type": .string("string"), "pattern": .string("^mc_[a-z0-9]{8}$")])
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ExecID: Codable, Equatable, Hashable, Sendable {
  public static let prefix: String = "ex_"
  public static let suffixLength: Int = 8

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }

  public static var jsonSchema: JSONValue {
    .object(["type": .string("string"), "pattern": .string("^ex_[a-z0-9]{8}$")])
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

private func hasPrefixedAlphanumericSuffix(_ candidate: String, prefix: String, count: Int) -> Bool {
  guard candidate.hasPrefix(prefix) else { return false }
  let suffix = candidate.dropFirst(prefix.count)
  guard suffix.count == count else { return false }
  return suffix.allSatisfy { $0.isASCII && (("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }
}
