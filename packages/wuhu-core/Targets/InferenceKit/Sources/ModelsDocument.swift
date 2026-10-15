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

  public init(providers: [String: Provider], groups: [String: Group] = [:]) {
    self.providers = providers
    self.groups = groups
  }

  public init(from decoder: any Decoder) throws {
    self.init(providers: try decoder.singleValueContainer().decode([String: Provider].self))
    try validateDeclarations()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(providers)
  }

  private func validateDeclarations() throws {
    for (id, provider) in providers {
      do {
        try provider.validateCapacity(providerID: id)
        if provider.transport == .websocket && provider.dialect != .responses && provider.dialect != .codex {
          throw CatalogError.invalidTransport(provider: id)
        }
      } catch let error as CatalogError {
        if let (group, declaration) = groups.sorted(by: { $0.key < $1.key }).first(where: { $0.value.members.contains(where: { $0.provider == id }) }),
           let member = declaration.members.first(where: { $0.provider == id })
        {
          throw CatalogError.groupMember(group: group, member: member.id, reason: error)
        }
        throw error
      }
    }
    let catalog = ProviderCatalog(document: self, credentials: .unavailable)
    for id in groups.keys.sorted() { _ = try catalog.validateGroup(id) }
  }

  public static let spacePath: String = "/models.json"
  public static let groupPath: String = "/model-groups.json"

  public struct Provider: Hashable, Sendable, Codable {
    public var dialect: Dialect
    public var baseURL: URL
    public var originator: String?
    public var transport: Transport?
    public var auth: Auth?
    public var capacity: [String: Double]?
    public var opaqueReplay: OpaqueReplay? {
      didSet { invalidOpaqueReplay = nil }
    }

    private var invalidOpaqueReplay: JSONValue?
    public var models: [String: Model]

    public init(dialect: Dialect, baseURL: URL, originator: String? = nil, transport: Transport? = nil, auth: Auth? = nil, capacity: [String: Double]? = nil, opaqueReplay: OpaqueReplay? = nil, models: [String: Model]) {
      self.dialect = dialect
      self.baseURL = baseURL
      self.originator = originator
      self.transport = transport
      self.auth = auth
      self.capacity = capacity
      self.opaqueReplay = opaqueReplay
      self.models = models
    }
  }

  public enum OpaqueReplay: String, Hashable, Sendable, Codable {
    case affine
    case none
  }

  public enum Auth: String, Hashable, Sendable, Codable {
    case oidc
  }

  public enum Transport: String, Hashable, Sendable, Codable {
    case sse
    case websocket
  }

  public enum Dialect: String, Hashable, Sendable, Codable {
    case anthropic
    case responses
    case codex
    case claude

    var images: ImageLimits {
      switch self {
      case .anthropic, .claude: .claude
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

    public init(
      maxInput: Int,
      maxOutput: Int,
      efforts: [String],
      defaultEffort: String,
      headroomOverride: Int? = nil,
      cacheWarming: CacheWarmingPolicy? = nil,
    ) {
      self.maxInput = maxInput
      self.maxOutput = maxOutput
      self.efforts = efforts
      self.defaultEffort = defaultEffort
      self.headroomOverride = headroomOverride
      self.cacheWarming = cacheWarming
    }

    enum CodingKeys: String, CodingKey {
      case maxInput, maxOutput, efforts, defaultEffort, headroomOverride, cacheWarming
    }

    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      maxInput = try values.decode(Int.self, forKey: .maxInput)
      maxOutput = try values.decode(Int.self, forKey: .maxOutput)
      efforts = try values.decode([String].self, forKey: .efforts)
      defaultEffort = try values.decode(String.self, forKey: .defaultEffort)
      headroomOverride = try values.decodeIfPresent(Int.self, forKey: .headroomOverride)
      if values.contains(.cacheWarming) {
        do { cacheWarming = try values.decode(CacheWarmingPolicy.self, forKey: .cacheWarming) }
        catch let error as CatalogError { throw error }
        catch { throw CatalogError.invalidCacheWarming(String(describing: error)) }
      } else { cacheWarming = nil }
    }

    public func budget(_ dialect: Dialect) -> ContextBudget {
      ContextBudget(maxInput: maxInput, maxOutput: maxOutput, headroomOverride: headroomOverride, images: dialect.images)
    }
  }
}

extension ModelsDocument {
  public init(json: Data, groupsJSON: Data? = nil) throws {
    let groups: [String: Group]
    do { groups = try groupsJSON.map { try JSONDecoder().decode(GroupDeclarations.self, from: $0).groups } ?? [:] }
    catch let error as CatalogError { throw error }
    catch { throw CatalogError.invalidGroupsDocument }
    do {
      let providers = try JSONDecoder().decode([String: Provider].self, from: json)
      self.init(providers: providers, groups: groups)
      try validateDeclarations()
    } catch let error as CatalogError { throw error }
    catch { throw CatalogError.invalidDocument }
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
    case .anthropic, .claude: host == "api.anthropic.com" ? .affine : .none
    case .responses: host == "api.openai.com" ? .affine : .none
    case .codex: host == "chatgpt.com" ? .affine : .none
    }
  }

  func validateConfiguration(providerID: String) throws {
    guard auth != .oidc || dialect != .codex else {
      throw CatalogError.invalidOIDCDialect(provider: providerID)
    }
    guard transport != .websocket || dialect == .responses || dialect == .codex else {
      throw CatalogError.invalidTransport(provider: providerID)
    }
    if let invalidOpaqueReplay {
      let value = if case let .string(value) = invalidOpaqueReplay { value } else { "non-string" }
      throw CatalogError.invalidOpaqueReplay(provider: providerID, value: value)
    }
  }

  // Keys this version no longer reads (the retired `acceptsUnsignedThinking`) are
  // ignored on decode and dropped on encode.
  private enum CodingKeys: String, CodingKey {
    case dialect, baseURL, originator, transport, auth, capacity, opaqueReplay, models
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dialect = try container.decode(ModelsDocument.Dialect.self, forKey: .dialect)
    baseURL = try container.decode(URL.self, forKey: .baseURL)
    originator = try container.decodeIfPresent(String.self, forKey: .originator)
    transport = try container.decodeIfPresent(ModelsDocument.Transport.self, forKey: .transport)
    auth = try container.decodeIfPresent(ModelsDocument.Auth.self, forKey: .auth)
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
    try container.encode(baseURL, forKey: .baseURL)
    try container.encodeIfPresent(originator, forKey: .originator)
    try container.encodeIfPresent(transport, forKey: .transport)
    try container.encodeIfPresent(auth, forKey: .auth)
    if let invalidOpaqueReplay { try container.encode(invalidOpaqueReplay, forKey: .opaqueReplay) }
    else { try container.encodeIfPresent(opaqueReplay, forKey: .opaqueReplay) }
    try container.encodeIfPresent(capacity, forKey: .capacity)
    try container.encode(models, forKey: .models)
  }
}
