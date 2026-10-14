import JSONValue

public struct HostedToolContent: Hashable, Sendable {
  public let replayScope: String?
  public let providerID: String
  public let type: String
  public let action: String
  public let payload: JSONValue

  public init?(providerID: String, payload: JSONValue, replayScope: String? = nil) {
    guard let item = payload.object,
          let type = item["type"]?.stringValue
    else { return nil }
    self.providerID = providerID
    self.replayScope = replayScope
    self.type = type
    action = item["action"]?.object?["type"]?.stringValue ?? "unknown"
    self.payload = payload
  }

  public var digest: String {
    let portableType = type == "web_search_call" ? type : "hosted_tool"
    let portableAction = ["search", "open_page", "find_in_page"].contains(action) ? action : "unknown"
    return "\(portableType) · \(portableAction)"
  }
}

extension HostedToolContent: Codable {
  enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case type
    case action
    case payload
    case replayScope = "replay_scope"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    replayScope = try container.decodeIfPresent(String.self, forKey: .replayScope)
    providerID = try container.decode(String.self, forKey: .providerID)
    type = try container.decode(String.self, forKey: .type)
    action = try container.decode(String.self, forKey: .action)
    payload = try container.decode(JSONValue.self, forKey: .payload)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(replayScope, forKey: .replayScope)
    try container.encode(providerID, forKey: .providerID)
    try container.encode(type, forKey: .type)
    try container.encode(action, forKey: .action)
    try container.encode(payload, forKey: .payload)
  }
}
