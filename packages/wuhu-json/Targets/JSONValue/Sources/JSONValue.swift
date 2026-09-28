#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OrderedCollections

public enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case integer(Int)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(OrderedDictionary<String, JSONValue>)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
      return
    }
    if let integer = try? container.decode(Int.self) {
      self = .integer(integer)
      return
    }
    if let number = try? container.decode(Double.self) {
      self = .number(number)
      return
    }
    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }
    if var unkeyed = try? decoder.unkeyedContainer() {
      var array: [JSONValue] = []
      if let count = unkeyed.count { array.reserveCapacity(count) }
      while !unkeyed.isAtEnd {
        array.append(try unkeyed.decode(JSONValue.self))
      }
      self = .array(array)
      return
    }
    if let keyed = try? decoder.container(keyedBy: ObjectKey.self) {
      // allKeys is document order in swift-foundation; ordered emission relies on
      // that implementation detail, asserted by a canary test rather than a contract.
      var object: OrderedDictionary<String, JSONValue> = [:]
      for key in keyed.allKeys {
        object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
      }
      self = .object(object)
      return
    }
    throw DecodingError.typeMismatch(
      JSONValue.self,
      .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"),
    )
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    case let .bool(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .integer(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .number(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .string(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .array(value):
      var container = encoder.unkeyedContainer()
      for element in value {
        try container.encode(element)
      }
    case let .object(value):
      var container = encoder.container(keyedBy: ObjectKey.self)
      for (key, element) in value {
        try container.encode(element, forKey: ObjectKey(key))
      }
    }
  }

  public static func parse(_ text: String) -> JSONValue? {
    parseJSON(Array(text.utf8))
  }

  public static func parse(utf8 bytes: some Sequence<UInt8>) -> JSONValue? {
    parseJSON(Array(bytes))
  }

  public func jsonString(sortedKeys: Bool = false, pretty: Bool = false) -> String {
    serialized(sortedKeys: sortedKeys, pretty: pretty)
  }
}

extension JSONValue {
  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null):
      true
    case let (.bool(a), .bool(b)):
      a == b
    case let (.integer(a), .integer(b)):
      a == b
    case let (.number(a), .number(b)):
      a == b
    case let (.integer(a), .number(b)):
      // Compare in Int space, not Double space: Double(a) rounds for |a| > 2^53
      // and would make == non-transitive. Int(exactly:) means each Double equals
      // at most one Int.
      Int(exactly: b) == a
    case let (.number(a), .integer(b)):
      Int(exactly: a) == b
    case let (.string(a), .string(b)):
      a == b
    case let (.array(a), .array(b)):
      a == b
    case let (.object(a), .object(b)):
      objectsEqual(a, b)
    default:
      false
    }
  }

  private static func objectsEqual(
    _ a: OrderedDictionary<String, JSONValue>,
    _ b: OrderedDictionary<String, JSONValue>,
  ) -> Bool {
    guard a.count == b.count else { return false }
    for (key, value) in a {
      guard let other = b[key], other == value else { return false }
    }
    return true
  }

  public func hash(into hasher: inout Hasher) {
    switch self {
    case .null:
      hasher.combine(0)
    case let .bool(value):
      hasher.combine(1)
      hasher.combine(value)
    case let .integer(value):
      // Numeric cases share a discriminant so an .integer and a .number that
      // compare equal land in the same bucket; an .integer always hashes its Int.
      hasher.combine(2)
      hasher.combine(value)
    case let .number(value):
      hasher.combine(2)
      // Mirror ==: a .number equal to some .integer(i) is exactly the one whose
      // Int(exactly:) is i, so hash that Int; otherwise hash the Double.
      if let int = Int(exactly: value) {
        hasher.combine(int)
      } else {
        hasher.combine(value)
      }
    case let .string(value):
      hasher.combine(3)
      hasher.combine(value)
    case let .array(value):
      hasher.combine(4)
      hasher.combine(value)
    case let .object(value):
      hasher.combine(5)
      // XOR per-entry hashes so object hashing stays key-order-insensitive,
      // matching the order-insensitive ==.
      var accumulated = 0
      for (key, element) in value {
        var entryHasher = Hasher()
        entryHasher.combine(key)
        entryHasher.combine(element)
        accumulated ^= entryHasher.finalize()
      }
      hasher.combine(accumulated)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .integer(value)
  }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .number(value)
  }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) {
    self = .array(elements)
  }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(OrderedDictionary(uniqueKeysWithValues: elements))
  }
}

public extension JSONValue {
  var object: OrderedDictionary<String, JSONValue>? {
    if case let .object(value) = self { return value }
    return nil
  }

  var array: [JSONValue]? {
    if case let .array(value) = self { return value }
    return nil
  }

  var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }

  var doubleValue: Double? {
    switch self {
    case let .integer(value):
      Double(value)
    case let .number(value):
      value
    default:
      nil
    }
  }

  var intValue: Int? {
    switch self {
    case let .integer(value):
      value
    case let .number(value) where value.isFinite:
      Int(exactly: value)
    default:
      nil
    }
  }

  var boolValue: Bool? {
    if case let .bool(value) = self { return value }
    return nil
  }
}

private struct ObjectKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue _: Int) {
    nil
  }
}
