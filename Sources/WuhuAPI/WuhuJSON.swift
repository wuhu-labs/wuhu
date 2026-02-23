import Foundation
import PiAI

public enum WuhuJSON {
  public static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }()

  public static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }()
}

public extension JSONEncoder {
  func encodeToJSONValue(_ value: some Encodable) throws -> JSONValue {
    let data = try encode(value)
    return try WuhuJSON.decoder.decode(JSONValue.self, from: data)
  }
}
