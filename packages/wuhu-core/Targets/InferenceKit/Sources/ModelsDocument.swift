#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ContextBudget
import struct SessionDomain.ImageLimits

public struct ModelsDocument: Hashable, Sendable, Codable {
  public var providers: [String: Provider]

  public init(providers: [String: Provider]) {
    self.providers = providers
  }

  public init(from decoder: any Decoder) throws {
    providers = try decoder.singleValueContainer().decode([String: Provider].self)
    for (id, provider) in providers where provider.transport == .websocket && provider.dialect != .responses && provider.dialect != .codex {
      throw CatalogError.invalidTransport(provider: id)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(providers)
  }

  public static let spacePath: String = "/models.json"

  public struct Provider: Hashable, Sendable, Codable {
    public var dialect: Dialect
    public var baseURL: URL
    public var originator: String?
    public var transport: Transport?
    public var auth: Auth?
    public var models: [String: Model]

    public init(dialect: Dialect, baseURL: URL, originator: String? = nil, transport: Transport? = nil, auth: Auth? = nil, models: [String: Model]) {
      self.dialect = dialect
      self.baseURL = baseURL
      self.originator = originator
      self.transport = transport
      self.auth = auth
      self.models = models
    }
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

    public init(
      maxInput: Int,
      maxOutput: Int,
      efforts: [String],
      defaultEffort: String,
      headroomOverride: Int? = nil,
    ) {
      self.maxInput = maxInput
      self.maxOutput = maxOutput
      self.efforts = efforts
      self.defaultEffort = defaultEffort
      self.headroomOverride = headroomOverride
    }

    public func budget(_ dialect: Dialect) -> ContextBudget {
      ContextBudget(maxInput: maxInput, maxOutput: maxOutput, headroomOverride: headroomOverride, images: dialect.images)
    }
  }
}

extension ModelsDocument {
  public init(json: Data) throws {
    self = try JSONDecoder().decode(ModelsDocument.self, from: json)
  }
}
