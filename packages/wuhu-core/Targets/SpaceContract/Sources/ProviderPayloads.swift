import Contract
import JSONValue

@Contract
public struct ProviderModel: Codable, Equatable, Sendable {
  public let id: String
  public let effortLevels: [String]
  public let defaultEffort: String?
}

// usedPercent is 0-100 and may pass 100 when a window runs over its cap;
// resetsAt is epoch seconds.
@Contract
public struct UsageWindow: Codable, Equatable, Sendable {
  public let name: String
  public let usedPercent: Double?
  public let resetsAt: Double?
  public let windowMinutes: Int?
}

@Contract
public struct ProviderUsage: Codable, Equatable, Sendable {
  public let plan: String?
  public let windows: [UsageWindow]
  public let observedAt: Double
}

// usage is nil until the server has observed it: only the codex and claude
// dialects report plan usage.
@Contract
public struct ProviderDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let dialect: String
  public let models: [ProviderModel]
  public let usage: ProviderUsage?
}

@Contract
public struct ProvidersOutput: Codable, Equatable, Sendable {
  public let providers: [ProviderDescriptor]
  public let groups: [ModelGroupDescriptor]?
  public let providerErrors: [CatalogEntryError]?
  public let groupErrors: [CatalogEntryError]?
}

@Contract
public struct ModelGroupMember: Codable, Equatable, Sendable {
  public let id: String
  public let provider: String
  public let model: String
}

@Contract
public struct ModelGroupDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let members: [ModelGroupMember]
  public let defaultEffort: String
  public let effortLevels: [String]
  public let policy: JSONValue
  public let memberErrors: [CatalogEntryError]?
}

@Contract
public struct CatalogEntryError: Codable, Equatable, Sendable {
  public let id: String
  public let message: String
}
