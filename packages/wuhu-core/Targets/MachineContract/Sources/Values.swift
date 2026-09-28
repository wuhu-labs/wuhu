import struct Foundation.Data
import JSONValue

public struct Base64Data: Codable, Equatable, Hashable, Sendable {
  public let bytes: [UInt8]

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  // Cursors count these decoded bytes, never base64 characters.
  public var count: Int { bytes.count }

  public static var jsonSchema: JSONValue {
    .object(["type": .string("string"), "contentEncoding": .string("base64")])
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let encoded = try container.decode(String.self)
    guard let data = Data(base64Encoded: encoded) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid base64 payload")
    }
    bytes = [UInt8](data)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Data(bytes).base64EncodedString())
  }
}

public struct StringMap: Codable, Equatable, Hashable, Sendable, ExpressibleByDictionaryLiteral {
  public let entries: [String: String]

  public init(_ entries: [String: String]) {
    self.entries = entries
  }

  public init(dictionaryLiteral elements: (String, String)...) {
    var entries: [String: String] = [:]
    for (key, value) in elements { entries[key] = value }
    self.entries = entries
  }

  public static var jsonSchema: JSONValue {
    .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")])])
  }

  public init(from decoder: any Decoder) throws {
    entries = try decoder.singleValueContainer().decode([String: String].self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }
}
