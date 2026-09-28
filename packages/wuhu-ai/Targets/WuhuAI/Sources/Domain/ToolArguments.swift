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

  public static func object(_ fields: OrderedDictionary<String, JSONValue>) -> ToolArguments {
    ToolArguments(.object(fields))
  }

  public var json: JSONValue {
    JSONValue.parse(text) ?? .object([:])
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
