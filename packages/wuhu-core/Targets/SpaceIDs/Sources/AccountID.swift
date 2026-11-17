public struct AccountID: RawRepresentable, Hashable, Sendable, Codable {
  private static let prefix: String = "ac_"
  public static let suffixLength: Int = 8

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(suffix: String) {
    self.rawValue = Self.prefix + suffix
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

public func hasPrefixedAlphanumericSuffix(_ candidate: String, prefix: String, count: Int) -> Bool {
  guard candidate.hasPrefix(prefix) else { return false }
  let suffix = candidate.dropFirst(prefix.count)
  guard suffix.count == count else { return false }
  return suffix.allSatisfy { $0.isASCII && (("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }
}
