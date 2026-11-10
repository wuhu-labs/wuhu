import JSONValue
import OrderedCollections

// The bytes a provider emitted for a tool call, kept verbatim: re-serializing a
// parsed value shuffles keys and breaks every prompt cache from that history
// item onward. Arguments we synthesize have no emitted bytes, so they serialize
// sorted — canonical, and stable under anyone who re-serializes later.
public struct ToolArguments: Hashable, Sendable {
  public let text: String

  private init(unchecked text: String) {
    self.text = text
  }

  public init(_ value: JSONValue) {
    self.init(unchecked: value.jsonString(sortedKeys: true))
  }

  public init?(verbatim text: String) {
    guard case .object = JSONValue.parse(text) else { return nil }
    self.init(unchecked: text)
  }

  /// What a model emitted, kept even when it is not a JSON object so the call can be refused and replayed as
  /// sent. Blank text is `{}`.
  public init(emitted text: String) {
    self.init(unchecked: text.allSatisfy(\.isWhitespace) ? "{}" : text)
  }

  public static func object(_ fields: OrderedDictionary<String, JSONValue>) -> ToolArguments {
    ToolArguments(.object(fields))
  }

  /// Nil when the model's text is not a JSON object (truncated or malformed): refuse the call, never run it as `{}`.
  public var object: OrderedDictionary<String, JSONValue>? {
    JSONValue.parse(text)?.object
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    guard let object else { throw InvalidToolArguments(text: text) }
    return try JSONValueDecoder().decode(type, from: .object(object))
  }

  // Anthropic `input` and Gemini `args` take only an object; the paired error result tells the model why.
  var wireObject: JSONValue {
    object.map(JSONValue.object) ?? .object([:])
  }
}

public struct InvalidToolArguments: Error, Hashable, Sendable, CustomStringConvertible {
  public let text: String

  public init(text: String) {
    self.text = text
  }

  public var description: String {
    "the arguments are not valid JSON (one JSON object); send the call again with complete arguments"
  }
}

extension ToolArguments: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self.init(unchecked: text)
    } else {
      self.init(try container.decode(JSONValue.self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(text)
  }
}
