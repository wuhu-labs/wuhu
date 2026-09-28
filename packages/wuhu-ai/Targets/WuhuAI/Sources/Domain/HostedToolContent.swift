import JSONValue

public struct HostedToolContent: Hashable, Sendable {
  public let providerID: String
  public let type: String
  public let action: String
  public let payload: JSONValue

  public init?(providerID: String, payload: JSONValue) {
    guard let item = payload.object,
          let type = item["type"]?.stringValue
    else { return nil }
    self.providerID = providerID
    self.type = type
    action = item["action"]?.object?["type"]?.stringValue ?? "unknown"
    self.payload = payload
  }

  public var digest: String {
    "\(type) · \(action)"
  }
}

extension HostedToolContent: Codable {
  enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case type
    case action
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    providerID = try container.decode(String.self, forKey: .providerID)
    type = try container.decode(String.self, forKey: .type)
    action = try container.decode(String.self, forKey: .action)
    payload = try container.decode(JSONValue.self, forKey: .payload)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(providerID, forKey: .providerID)
    try container.encode(type, forKey: .type)
    try container.encode(action, forKey: .action)
    try container.encode(payload, forKey: .payload)
  }
}
