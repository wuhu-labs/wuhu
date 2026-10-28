#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct SessionDomain.ContextBudget
import struct SessionDomain.ImageLimits

public struct ModelsDocument: Hashable, Sendable, Codable {
  public var providers: [String: Provider]
  public var groups: [String: Group]
  public private(set) var providerErrors: [String: CatalogError] = [:]
  public private(set) var groupErrors: [String: CatalogError] = [:]

  public init(providers: [String: Provider], groups: [String: Group] = [:]) {
    self.providers = providers
    self.groups = groups
  }

  public init(from decoder: any Decoder) throws {
    let entries = try decoder.singleValueContainer().decode([String: CatalogEntry<Provider>].self)
    self.init(providers: entries.compactMapValues(\.value))
    providerErrors = entries.compactMapValues(\.error)
  }

  public func encode(to encoder: any Encoder) throws {
    if let error = providerErrors.sorted(by: { $0.key < $1.key }).first?.value { throw error }
    var container = encoder.singleValueContainer()
    try container.encode(providers)
  }

  public static let spacePath: String = "/models.json"
  public static let groupPath: String = "/model-groups.json"

  public struct Provider: Hashable, Sendable, Codable {
    public var dialect: Dialect
    public var imageFamily: ImageFamily?

    public var images: ImageLimits { imageFamily?.limits ?? dialect.images }
    public var baseURL: URL
    public var originator: String?
    public var transport: Transport?
    public var auth: Auth?
    public var usage: UsageSource?
    public var capacity: [String: Double]?
    public var opaqueReplay: OpaqueReplay? {
      didSet { invalidOpaqueReplay = nil }
    }

    private var invalidOpaqueReplay: JSONValue?
    public var models: [String: Model]

    public init(dialect: Dialect, baseURL: URL, imageFamily: ImageFamily? = nil, originator: String? = nil, transport: Transport? = nil, auth: Auth? = nil, usage: UsageSource? = nil, capacity: [String: Double]? = nil, opaqueReplay: OpaqueReplay? = nil, models: [String: Model]) {
      self.dialect = dialect
      self.imageFamily = imageFamily
      self.baseURL = baseURL
      self.originator = originator
      self.transport = transport
      self.auth = auth
      self.usage = usage
      self.capacity = capacity
      self.opaqueReplay = opaqueReplay
      self.models = models
    }
  }

  public enum ImageFamily: String, Hashable, Sendable, Codable {
    case claude
    case openAI

    var limits: ImageLimits {
      switch self {
      case .claude: .claude
      case .openAI: .openAI
      }
    }
  }

  public enum OpaqueReplay: String, Hashable, Sendable, Codable {
    case affine
    case none
  }

  public enum Auth: String, Hashable, Sendable, Codable {
    case oidc
  }

  /// A plan-usage read the provider serves at `<baseURL>/usage` without an
  /// inference. Codex providers are read through their own backend regardless.
  public enum UsageSource: String, Hashable, Sendable, Codable {
    case gateway
  }

  public enum Transport: String, Hashable, Sendable, Codable {
    case sse
    case websocket
  }

  public enum Dialect: String, Hashable, Sendable, Codable {
    case anthropic
    case responses
    case codex

    var images: ImageLimits {
      switch self {
      case .anthropic: .claude
      case .responses, .codex: .openAI
      }
    }
  }

  public struct Model: Hashable, Sendable, Codable {
    public var maxInput: Int
    public var maxOutput: Int
    public var efforts: [String]
    public var defaultEffort: String
    public var headroomOverride: Int?
    public var cacheWarming: CacheWarmingPolicy?
    public var usageWindows: [String]?

    var bindingWindows: [String] { usageWindows ?? ["five_hour", "seven_day"] }

    public init(
      maxInput: Int,
      maxOutput: Int,
      efforts: [String],
      defaultEffort: String,
      headroomOverride: Int? = nil,
      cacheWarming: CacheWarmingPolicy? = nil,
      usageWindows: [String]? = nil,
    ) {
      self.maxInput = maxInput
      self.maxOutput = maxOutput
      self.efforts = efforts
      self.defaultEffort = defaultEffort
      self.headroomOverride = headroomOverride
      self.cacheWarming = cacheWarming
      self.usageWindows = usageWindows
    }

    enum CodingKeys: String, CodingKey {
      case maxInput, maxOutput, efforts, defaultEffort, headroomOverride, cacheWarming, usageWindows
    }

    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      maxInput = try values.decode(Int.self, forKey: .maxInput)
      maxOutput = try values.decode(Int.self, forKey: .maxOutput)
      efforts = try values.decode([String].self, forKey: .efforts)
      defaultEffort = try values.decode(String.self, forKey: .defaultEffort)
      headroomOverride = try values.decodeIfPresent(Int.self, forKey: .headroomOverride)
      usageWindows = try values.decodeIfPresent([String].self, forKey: .usageWindows)
      if values.contains(.cacheWarming) {
        do { cacheWarming = try values.decode(CacheWarmingPolicy.self, forKey: .cacheWarming) }
        catch let error as CatalogError { throw error }
        catch { throw CatalogError.invalidCacheWarming(String(describing: error)) }
      } else { cacheWarming = nil }
    }

    public func budget(images: ImageLimits) -> ContextBudget {
      ContextBudget(maxInput: maxInput, maxOutput: maxOutput, headroomOverride: headroomOverride, images: images)
    }
  }
}

extension ModelsDocument {
  public init(json: Data, groupsJSON: Data? = nil) throws {
    do {
      self = try JSONDecoder().decode(Self.self, from: json)
    } catch { throw CatalogError.invalidDocument }
    do {
      let entries = try groupsJSON.map { try JSONDecoder().decode([String: CatalogEntry<Group>].self, from: $0) } ?? [:]
      groups = entries.compactMapValues(\.value)
      groupErrors = entries.compactMapValues(\.error)
      for (id, error) in groupErrors {
        let reason = if case let .invalidProvider(_, reason) = error { reason } else { error.description }
        groupErrors[id] = .invalidGroup(group: id, reason: reason)
      }
    } catch { throw CatalogError.invalidGroupsDocument }
  }
}

extension ModelsDocument.Provider {
  public var effectiveOpaqueReplay: ModelsDocument.OpaqueReplay {
    if invalidOpaqueReplay != nil { return .none }
    if let opaqueReplay { return opaqueReplay }
    guard baseURL.scheme?.lowercased() == "https", baseURL.user == nil, baseURL.password == nil,
          baseURL.port == nil || baseURL.port == 443 else { return .none }
    let host = baseURL.host?.lowercased()
    return switch dialect {
    case .anthropic: host == "api.anthropic.com" ? .affine : .none
    case .responses: host == "api.openai.com" ? .affine : .none
    case .codex: host == "chatgpt.com" ? .affine : .none
    }
  }

  func validateConfiguration(providerID: String) throws(CatalogError) {
    guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
          baseURL.user == nil, baseURL.password == nil
    else {
      throw CatalogError.invalidEndpoint(provider: providerID)
    }
    guard auth != .oidc || dialect != .codex else {
      throw CatalogError.invalidOIDCDialect(provider: providerID)
    }
    guard transport != .websocket || dialect == .responses || dialect == .codex else {
      throw CatalogError.invalidTransport(provider: providerID)
    }
    guard usage == nil || dialect == .responses && auth != .oidc else {
      throw CatalogError.invalidUsageSource(provider: providerID)
    }
    if let invalidOpaqueReplay {
      let value = if case let .string(value) = invalidOpaqueReplay { value } else { "non-string" }
      throw CatalogError.invalidOpaqueReplay(provider: providerID, value: value)
    }
  }

  // Keys this version no longer reads (the retired `acceptsUnsignedThinking`) are
  // ignored on decode and dropped on encode.
  private enum CodingKeys: String, CodingKey {
    case dialect, imageFamily, baseURL, originator, transport, auth, usage, capacity, opaqueReplay, models
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dialect = try container.decode(ModelsDocument.Dialect.self, forKey: .dialect)
    imageFamily = try container.decodeIfPresent(ModelsDocument.ImageFamily.self, forKey: .imageFamily)
    baseURL = try container.decode(URL.self, forKey: .baseURL)
    originator = try container.decodeIfPresent(String.self, forKey: .originator)
    transport = try container.decodeIfPresent(ModelsDocument.Transport.self, forKey: .transport)
    auth = try container.decodeIfPresent(ModelsDocument.Auth.self, forKey: .auth)
    usage = try container.decodeIfPresent(ModelsDocument.UsageSource.self, forKey: .usage)
    capacity = try container.decodeIfPresent([String: Double].self, forKey: .capacity)
    models = try container.decode([String: ModelsDocument.Model].self, forKey: .models)
    if let value = try container.decodeIfPresent(JSONValue.self, forKey: .opaqueReplay) {
      if case let .string(raw) = value, let setting = ModelsDocument.OpaqueReplay(rawValue: raw) {
        opaqueReplay = setting
      } else {
        invalidOpaqueReplay = value
      }
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(dialect, forKey: .dialect)
    try container.encodeIfPresent(imageFamily, forKey: .imageFamily)
    try container.encode(baseURL, forKey: .baseURL)
    try container.encodeIfPresent(originator, forKey: .originator)
    try container.encodeIfPresent(transport, forKey: .transport)
    try container.encodeIfPresent(auth, forKey: .auth)
    try container.encodeIfPresent(usage, forKey: .usage)
    if let invalidOpaqueReplay { try container.encode(invalidOpaqueReplay, forKey: .opaqueReplay) }
    else { try container.encodeIfPresent(opaqueReplay, forKey: .opaqueReplay) }
    try container.encodeIfPresent(capacity, forKey: .capacity)
    try container.encode(models, forKey: .models)
  }
}

private enum CatalogEntry<Value: Decodable>: Decodable {
  case valid(Value)
  case invalid(CatalogError)

  init(from decoder: any Decoder) throws {
    do { self = .valid(try Value(from: decoder)) }
    catch let error as CatalogError { self = .invalid(error) }
    catch { self = .invalid(.invalidProvider(provider: decoder.codingPath.last!.stringValue, reason: String(describing: error))) }
  }

  var value: Value? {
    if case let .valid(value) = self { value } else { nil }
  }

  var error: CatalogError? {
    if case let .invalid(error) = self { error } else { nil }
  }
}
