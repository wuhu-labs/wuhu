#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Credentials
import Fetch
import JSONValue

public struct CapabilityError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
  public enum Code: String, Sendable, Codable {
    case providerNotConfigured = "provider_not_configured"
    case providerAuth = "provider_auth"
    case providerRegion = "provider_region"
    case providerEntitlement = "provider_entitlement"
    case providerRateLimited = "provider_rate_limited"
    case unsupportedFeature = "unsupported_feature"
    case invalidArgument = "invalid_argument"
    case providerUnavailable = "provider_unavailable"
  }

  public var code: Code
  public var message: String
  public var hint: String
  public var description: String { "\(code.rawValue): \(message) (\(hint))" }

  public init(_ code: Code, _ message: String, hint: String = "Check /capabilities.json and the server provider credentials.") {
    self.code = code
    self.message = message
    self.hint = hint
  }
}

struct CapabilitiesDocument: Sendable, Codable {
  static let spacePath: String = "/capabilities.json"

  struct Selection: Sendable, Codable {
    var active: String?
    var providers: [String: Variant]

    enum CodingKeys: String, CodingKey { case active, providers }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      active = try container.decodeIfPresent(String.self, forKey: .active)
      providers = try container.decodeIfPresent([String: Variant].self, forKey: .providers) ?? [:]
    }
  }

  struct Variant: Sendable, Codable {
    var dialect: String
    var credential: String?
    var baseURL: URL?
    var model: String?
    var models: [String: Facts]?
  }

  struct Facts: Sendable, Codable {
    var edit: Bool?
    var timestamps: [String]?
    var diarize: Bool?
  }

  var webSearch: Selection?
  var image: Selection?
  var transcription: Selection?

  enum CodingKeys: String, CodingKey {
    case webSearch = "web_search", image, transcription
  }

  init(json: Data) throws {
    do { self = try JSONDecoder().decode(Self.self, from: json) }
    catch { throw CapabilityError(.providerNotConfigured, "Invalid /capabilities.json.") }
  }
}

public struct CapabilityOptions: Sendable, Codable {
  public var provider: String?
  public var model: String?
  public var quality: String?
  public var size: String?
  public var language: String?
  public var timestamps: [String]?
  public var diarize: Bool?
  public var count: Int?

  public init(provider: String? = nil, model: String? = nil, quality: String? = nil, size: String? = nil, language: String? = nil, timestamps: [String]? = nil, diarize: Bool? = nil, count: Int? = nil) {
    self.provider = provider
    self.model = model
    self.quality = quality
    self.size = size
    self.language = language
    self.timestamps = timestamps
    self.diarize = diarize
    self.count = count
  }
}

public struct CapabilityClient: Sendable {
  let document: CapabilitiesDocument?
  let models: ModelsDocument
  let credentials: CredentialResolver

  init(document: CapabilitiesDocument?, models: ModelsDocument = .init(providers: [:]), credentials: CredentialResolver) {
    self.document = document
    self.models = models
    self.credentials = credentials
  }

  enum Kind { case search, image, transcription }

  struct Resolved: Sendable {
    let provider: String
    let dialect: String
    let baseURL: URL
    let model: String
    let facts: CapabilitiesDocument.Facts
    let headers: RequestHeaders
  }

  struct Configuration {
    let provider: String
    let dialect: String
    let baseURL: URL
    let model: String
    let facts: CapabilitiesDocument.Facts
    let credentialID: String
  }

  public func capability(_ kind: String) throws -> JSONValue {
    let selected: Kind = switch kind {
    case "web_search": .search
    case "image": .image
    case "transcription": .transcription
    default: throw CapabilityError(.invalidArgument, "Capability kind is image, transcription or web_search.")
    }
    let config = try configuration(selected, options: .init())
    return .object([
      "kind": .string(kind),
      "provider": .string(config.provider),
      "dialect": .string(config.dialect),
      "model": .string(config.model),
      "authentication": .string("not_checked"),
      "features": .object([
        "edit": config.facts.edit.map(JSONValue.bool) ?? .bool(false),
        "timestamps": .array((config.facts.timestamps ?? []).map(JSONValue.string)),
        "diarize": .bool(config.facts.diarize ?? false),
      ]),
    ])
  }

  func resolve(_ kind: Kind, options: CapabilityOptions) async throws -> Resolved {
    let config = try configuration(kind, options: options)
    let credential: ProviderCredential?
    do { credential = try await credentials.resolve(config.credentialID) }
    catch { throw CapabilityError(.providerAuth, "Cannot resolve credentials for '\(config.credentialID)'.", hint: "Refresh the provider login on the server host.") }
    var headers = RequestHeaders()
    headers.set("user-agent", kind == .transcription ? TranscriberTransport.userAgent : "wuhu-capabilities/1")
    if config.dialect == "codex" {
      guard case let .chatGPT(token, account)? = credential else {
        throw CapabilityError(.providerNotConfigured, "Provider '\(config.credentialID)' needs a ChatGPT login.", hint: "Run wuhu auth login \(config.credentialID) on the server host.")
      }
      headers.setSensitive("authorization", "Bearer \(token)")
      headers.setSensitive("chatgpt-account-id", account)
      headers.set("originator", models.providers[config.credentialID]?.originator ?? "wuhu")
    } else {
      guard case let .apiKey(key)? = credential, !key.isEmpty else {
        throw CapabilityError(.providerNotConfigured, "Provider '\(config.credentialID)' needs an API key.", hint: "Run wuhu auth set \(config.credentialID) on the server host, supplying the key on stdin.")
      }
      headers.setSensitive(config.dialect == "brave" ? "x-subscription-token" : config.dialect == "exa" ? "x-api-key" : "authorization", config.dialect == "brave" || config.dialect == "exa" ? key : "Bearer \(key)")
    }
    return .init(provider: config.provider, dialect: config.dialect, baseURL: config.baseURL, model: config.model, facts: config.facts, headers: headers)
  }

  private func configuration(_ kind: Kind, options: CapabilityOptions) throws -> Configuration {
    let selection = switch kind {
    case .search: document?.webSearch
    case .image: document?.image
    case .transcription: document?.transcription
    }
    let id = options.provider ?? selection?.active ?? "codex"
    let variant: CapabilitiesDocument.Variant
    if let configured = selection?.providers[id] {
      variant = configured
    } else if selection == nil, id == "codex" {
      variant = .init(dialect: "codex")
    } else if selection?.active == nil, selection?.providers.isEmpty == true, id == "codex" {
      variant = .init(dialect: "codex")
    } else {
      throw CapabilityError(.providerNotConfigured, "Capability provider '\(id)' is not configured.")
    }
    let allowed = switch kind {
    case .search: ["codex", "brave", "exa"]
    case .image: ["codex", "openai-images", "dashscope"]
    case .transcription: ["codex", "openai-audio", "dashscope"]
    }
    guard allowed.contains(variant.dialect) else {
      throw CapabilityError(.providerNotConfigured, "Dialect '\(variant.dialect)' does not implement this capability.")
    }
    let credentialID = variant.credential ?? (variant.dialect == "codex" ? models.providers.sorted(by: { $0.key < $1.key }).first(where: { $0.value.dialect == .codex })?.key ?? "codex" : id)
    let defaultURL = switch variant.dialect {
    case "codex": models.providers[credentialID]?.baseURL ?? URL(string: "https://chatgpt.com/backend-api/codex")!
    case "brave": URL(string: "https://api.search.brave.com/res/v1")!
    case "exa": URL(string: "https://api.exa.ai")!
    case "dashscope": URL(string: "https://dashscope.aliyuncs.com/api/v1")!
    default: URL(string: "https://api.openai.com/v1")!
    }
    let baseURL = variant.baseURL ?? defaultURL
    guard ["http", "https"].contains(baseURL.scheme), baseURL.host != nil, baseURL.user == nil, baseURL.password == nil else {
      throw CapabilityError(.providerNotConfigured, "Provider baseURL must be an HTTP(S) endpoint without user information.")
    }
    var model = options.model ?? variant.model ?? defaultModel(kind, dialect: variant.dialect)
    if kind == .image, variant.dialect == "dashscope", let quality = options.quality {
      guard options.model == nil else { throw CapabilityError(.invalidArgument, "Choose model or quality, not both.") }
      guard let mapped = ["draft": "z-image-turbo", "standard": "qwen-image-3.0", "fine": "qwen-image-3.0-pro", "ultra": "wan2.7-image-pro"][quality] else {
        throw CapabilityError(.invalidArgument, "Quality must be draft, standard, fine or ultra.")
      }
      model = mapped
    }
    let known = modelFacts(model, dialect: variant.dialect, kind: kind)
    let configured = variant.models?[model]
    let facts = CapabilitiesDocument.Facts(edit: configured?.edit ?? known.edit, timestamps: configured?.timestamps ?? known.timestamps, diarize: configured?.diarize ?? known.diarize)
    return .init(provider: id, dialect: variant.dialect, baseURL: baseURL, model: model, facts: facts, credentialID: credentialID)
  }

  func defaultModel(_ kind: Kind, dialect: String) -> String {
    switch (kind, dialect) {
    case (.search, "codex"): models.providers.sorted(by: { $0.key < $1.key }).first(where: { $0.value.dialect == .codex })?.value.models.keys.sorted().first ?? "gpt-5"
    case (.image, "dashscope"): "qwen-image-3.0"
    case (.image, "openai-images"): "gpt-image-1"
    case (.image, _): "gpt-image-2"
    case (.transcription, "codex"): "chatgpt-transcribe"
    case (.transcription, "dashscope"): "qwen-audio-3.1-asr-flash-filetrans"
    case (.transcription, _): OpenAITranscriber.defaultModel
    default: dialect
    }
  }

  func modelFacts(_ model: String, dialect: String, kind: Kind) -> CapabilitiesDocument.Facts {
    switch (kind, dialect) {
    case (.image, "codex"): .init(edit: model == "gpt-image-2")
    case (.image, "openai-images"): .init(edit: ["gpt-image-1", "gpt-image-1-mini", "gpt-image-1.5", "gpt-image-2", "gpt-image-2.5", "gpt-image-2.5-flare", "gpt-image-2.5-sunburst"].contains(model))
    case (.image, "dashscope"): .init(edit: ["qwen-image-3.0", "qwen-image-3.0-pro", "wan2.7-image-pro", "qwen-image-edit-plus", "qwen-image-edit-max"].contains(model))
    case (.transcription, "dashscope") where ["qwen-audio-3.1-asr-flash-filetrans", "qwen3-asr-flash-filetrans"].contains(model): .init(timestamps: ["words", "segments"], diarize: model == "qwen-audio-3.1-asr-flash-filetrans")
    case (.transcription, "openai-audio") where model == "whisper-1": .init(timestamps: ["words", "segments"], diarize: false)
    case (.transcription, "openai-audio") where model == "gpt-4o-transcribe-diarize": .init(timestamps: ["segments"], diarize: true)
    default: .init(timestamps: [], diarize: false)
    }
  }
}

extension CapabilityClient {
  public static func load(read: @Sendable (String) async throws -> Data?, credentials: CredentialResolver) async throws -> Self {
    let data: Data?
    do { data = try await read(CapabilitiesDocument.spacePath) }
    catch { throw CapabilityError(.providerNotConfigured, "Cannot read /capabilities.json.") }
    let document = try data.map { try CapabilitiesDocument(json: $0) }
    let modelsData = try await read(ModelsDocument.spacePath)
    let models = modelsData.flatMap { try? ModelsDocument(json: $0) } ?? .init(providers: [:])
    return .init(document: document, models: models, credentials: credentials)
  }
}
