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
}
