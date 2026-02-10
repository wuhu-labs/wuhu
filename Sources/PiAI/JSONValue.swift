import Foundation

/// A Sendable, Hashable representation of JSON.
///
/// This is used for tool schemas and tool call arguments/results.
public enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

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
    if let number = try? container.decode(Double.self) {
      self = .number(number)
      return
    }
    if let string = try? container.decode(String.self) {
      self = .string(string)
      return
    }
    if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
      return
    }
    if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
      return
    }
    throw DecodingError.typeMismatch(
      JSONValue.self,
      .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"),
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }

  public static func fromAny(_ any: Any) throws -> JSONValue {
    switch any {
    case is NSNull:
      return .null
    case let value as Bool:
      return .bool(value)
    case let value as Int:
      return .number(Double(value))
    case let value as Double:
      return .number(value)
    case let value as Float:
      return .number(Double(value))
    case let value as String:
      return .string(value)
    case let value as [Any]:
      return try .array(value.map(JSONValue.fromAny))
    case let value as [String: Any]:
      var object: [String: JSONValue] = [:]
      object.reserveCapacity(value.count)
      for (k, v) in value {
        object[k] = try JSONValue.fromAny(v)
      }
      return .object(object)
    default:
      throw PiAIError.decoding("Unsupported JSON value type: \(type(of: any))")
    }
  }

  public func toAny() -> Any {
    switch self {
    case .null:
      NSNull()
    case let .bool(value):
      value
    case let .number(value):
      value
    case let .string(value):
      value
    case let .array(value):
      value.map { $0.toAny() }
    case let .object(value):
      value.mapValues { $0.toAny() }
    }
  }
}

public extension JSONValue {
  var object: [String: JSONValue]? {
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
    if case let .number(value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case let .bool(value) = self { return value }
    return nil
  }
}
