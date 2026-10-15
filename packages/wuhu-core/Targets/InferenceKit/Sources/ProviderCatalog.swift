import enum Credentials.ChatGPTAuthError
import struct Credentials.CredentialBinding
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ContextBudget
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionID
import WuhuAI

public indirect enum CatalogError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidDocument
  case invalidGroupsDocument
  case unknownProvider(String)
  case unsupportedTarget(String)
  case unknownGroup(String)
  case noUsableMembers(String)
  case invalidCapacity(provider: String, window: String)
  case invalidGroup(group: String, reason: String)
  case groupMember(group: String, member: String, reason: CatalogError)
  case credentialLoginRequired(provider: String)
  case modelRouteInvalid(group: String, member: String)
  case invalidModel(provider: String, model: String)
  case oidcNotConfigured(provider: String)
  case unknownModel(provider: String, model: String)
  case unknownEffort(provider: String, model: String, effort: String)
  case missingCredential(provider: String)
  case credentialMismatch(provider: String)
  case invalidEndpoint(provider: String)
  case invalidTransport(provider: String)
  case invalidCacheWarming(String)
  case invalidOIDCDialect(provider: String)
  case claudeAPIKeyRequired(provider: String)
  case invalidOpaqueReplay(provider: String, value: String)
  case unsignedThinkingRequiresAnthropic(provider: String)
  case opaqueReplayRequiresNoThinking(provider: String, model: String)

  public var description: String {
    switch self {
    case .invalidGroupsDocument: "invalid /model-groups.json catalog shape"
    case .invalidDocument: "invalid /models.json catalog shape"
    case let .unsupportedTarget(target): "unsupported model target: \(target); this operation requires a concrete provider/model"
    case let .noUsableMembers(group): "model group \(group) has no usable member"
    case let .invalidCapacity(provider, window): "invalid capacity for provider \(provider), window \(window): use positive fiveHour/sevenDay numbers"
    case let .unknownGroup(group): "unknown model group: \(group)"
    case let .invalidGroup(group, reason): "invalid model group \(group): \(reason)"
    case let .groupMember(group, member, reason): "model group \(group) member \(member): \(reason.description)"
    case let .credentialLoginRequired(provider): "credentialLoginRequired: \(provider) requires login after credential refresh refusal"
    case let .modelRouteInvalid(group, member): "modelRouteInvalid: model group \(group) pinned member \(member) was removed or rebound; restore it or Start over"
    case let .invalidModel(provider, model): "invalid context/output limits for \(provider)/\(model)"
    case let .oidcNotConfigured(provider): "OIDC authentication is not configured for provider \(provider)"
    case let .invalidCacheWarming(reason):
      "invalid cacheWarming configuration: \(reason)"
    case let .invalidOpaqueReplay(provider, value):
      "invalid opaqueReplay \"\(value)\" for provider \(provider); expected affine or none"
    case let .unsignedThinkingRequiresAnthropic(provider):
      "acceptsUnsignedThinking requires an Anthropic Messages provider: \(provider)"
    case let .opaqueReplayRequiresNoThinking(provider, model):
      "model \(provider)/\(model) cannot use thinking effort with opaqueReplay: none (request none effort or set opaqueReplay: affine only with upstream account affinity)"
    case let .claudeAPIKeyRequired(provider):
      "claude provider needs an API key; Claude Code tokens are only usable through the gateway: \(provider)"
    case let .invalidOIDCDialect(provider):
      "OIDC authentication is unsupported for Codex providers: \(provider)"
    case let .invalidEndpoint(provider): "provider endpoint must be an HTTP(S) URL without user information: \(provider)"
    case let .invalidTransport(provider):
      "websocket transport requires a Responses or Codex provider: \(provider)"
    case let .unknownProvider(provider):
      "unknown provider: \(provider) (edit \(ModelsDocument.spacePath) or run `wuhu models update`)"
    case let .unknownModel(provider, model):
      "unknown model: \(provider)/\(model)"
    case let .unknownEffort(provider, model, effort):
      "unknown effort \"\(effort)\" for \(provider)/\(model)"
    case let .missingCredential(provider):
      "no credentials for provider \(provider) (run `wuhu auth set \(provider)` or `wuhu auth login \(provider)`)"
    case let .credentialMismatch(provider):
      "credentials for provider \(provider) are the wrong kind for its dialect (api key vs chatgpt login)"
    }
  }
}

public struct ResolvedModel: Sendable {
  public var specifier: ModelSpecifier
  public var endpoint: any ModelEndpoint
  public var budget: ContextBudget
  public var transport: ModelsDocument.Transport
  public var replayScope: String?
  public var bindingIdentity: String
  public var routeEpoch: String
  var socketIdentity: SocketRegistryIdentity?

  public init(specifier: ModelSpecifier, endpoint: any ModelEndpoint, budget: ContextBudget, transport: ModelsDocument.Transport = .sse, replayScope: String? = nil, bindingIdentity: String = UUID().uuidString, routeEpoch: String = "0") {
    self.specifier = specifier
    self.endpoint = endpoint
    self.budget = budget
    self.transport = transport
    self.replayScope = replayScope
    self.bindingIdentity = bindingIdentity
    self.routeEpoch = routeEpoch
  }
}

public struct ProviderCatalog: Sendable {
  public var document: ModelsDocument
  public var credentials: CredentialResolver
  let oidcReadiness: (@Sendable (URL) async throws -> Void)?
  let oidcToken: (@Sendable (URL, SessionID) async throws -> String)?
  private let oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String?)?
  private let receiveCodexResponseHeaders: @Sendable (String, [String: String]) async -> Void

  public init(
    document: ModelsDocument,
    credentials: CredentialResolver,
    oidcToken: (@Sendable (URL, SessionID) async throws -> String)? = nil,
    oidcReadiness: (@Sendable (URL) async throws -> Void)? = nil,
    oidcBindingIdentity: (@Sendable (URL, SessionID) async throws -> String?)? = nil,
    receiveCodexResponseHeaders: @escaping @Sendable (String, [String: String]) async -> Void = { _, _ in },
  ) {
    self.document = document
    self.credentials = credentials
    self.oidcReadiness = oidcReadiness
    self.oidcToken = oidcToken
    self.oidcBindingIdentity = oidcBindingIdentity
    self.receiveCodexResponseHeaders = receiveCodexResponseHeaders
  }

  @discardableResult
  public func validate(_ specifier: ModelSpecifier) throws -> ModelsDocument.Model {
    if document.groups[specifier.provider] != nil { throw CatalogError.unsupportedTarget(specifier.provider) }
    guard let provider = document.providers[specifier.provider] else {
      throw CatalogError.unknownProvider(specifier.provider)
    }
    try provider.validateCapacity(providerID: specifier.provider)
    guard ["http", "https"].contains(provider.baseURL.scheme?.lowercased() ?? ""), provider.baseURL.host != nil,
          provider.baseURL.user == nil, provider.baseURL.password == nil
    else {
      throw CatalogError.invalidEndpoint(provider: specifier.provider)
    }
    try provider.validateConfiguration(providerID: specifier.provider)
    guard let model = provider.models[specifier.model] else {
      throw CatalogError.unknownModel(provider: specifier.provider, model: specifier.model)
    }
    guard model.maxInput > 0, model.maxOutput > 0, model.maxOutput < model.maxInput,
          (model.headroomOverride ?? model.maxOutput) >= 0,
          (model.headroomOverride ?? model.maxOutput) < model.maxInput,
          model.efforts.contains(model.defaultEffort)
    else {
      throw CatalogError.invalidModel(provider: specifier.provider, model: specifier.model)
    }
    guard model.efforts.contains(specifier.effort) else {
      throw CatalogError.unknownEffort(
        provider: specifier.provider,
        model: specifier.model,
        effort: specifier.effort,
      )
    }
    try provider.validateReplayConfiguration(providerID: specifier.provider, model: specifier.model, effort: specifier.effort)
    return model
  }

  public func defaultSpecifier(provider providerID: String, model modelName: String) throws -> ModelSpecifier {
    if document.groups[providerID] != nil { throw CatalogError.unsupportedTarget(providerID) }
    guard let provider = document.providers[providerID] else {
      throw CatalogError.unknownProvider(providerID)
    }
    guard let model = provider.models[modelName] else {
      throw CatalogError.unknownModel(provider: providerID, model: modelName)
    }
    return ModelSpecifier(provider: providerID, model: modelName, effort: model.defaultEffort)
  }

  // Resolution runs inside the session loop's retry, so it speaks the loop's
  // failure vocabulary: a credential-refresh hop that cannot reach the network
  // must arrive as a transport failure, not as an opaque error the loop reads
  // as terminal.
  public func resolve(
    _ specifier: ModelSpecifier,
    session: SessionID,
    routeEpoch: String = "0",
  ) async throws(InferenceError) -> ResolvedModel {
    let model: ModelsDocument.Model
    do {
      model = try validate(specifier)
    } catch let error as CatalogError {
      throw .invalidInput(status: 422, body: error.description)
    } catch {
      throw InferenceError.normalize(error)
    }
    let provider = document.providers[specifier.provider]!
    if provider.auth == .oidc {
      guard let oidcToken else {
        throw .invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")
      }
      let token: String
      let identity: String?
      do {
        identity = try await oidcBindingIdentity?(provider.baseURL, session)
        token = try await oidcToken(provider.baseURL, session)
        if let identity, try await oidcBindingIdentity?(provider.baseURL, session) != identity {
          throw InferenceError.invalidInput(status: 422, body: "OIDC replay identity changed while signing; resolve the provider again.")
        }
      } catch {
        let failure = InferenceError.normalize(error)
        // Unknown signer diagnostics may contain private key or credential material.
        if case let .other(status, _) = failure { throw .other(status: status, body: nil) }
        throw failure
      }
      let epoch = if let identity { identity } else {
        await UnverifiedOIDCIdentities.shared.epoch(provider: specifier.provider, token: token)
      }
      let bindingIdentity = provider.bindingIdentity(providerID: specifier.provider, credentialEpoch: epoch)
      let replayScope = provider.effectiveOpaqueReplay == .affine && identity != nil ? bindingIdentity : nil
      let cacheKey = replayCacheKey(session: session, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
      let endpoint: any ModelEndpoint
      switch provider.dialect {
      case .responses:
        endpoint = OpenAIGPTEndpoint(model: specifier.model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: provider.baseURL, apiKey: token, promptCacheKey: cacheKey)
      case .anthropic, .claude:
        endpoint = OIDCAnthropicEndpoint(model: specifier.model, baseURL: provider.baseURL, token: token, deepSeek: specifier.provider == "deepseek", acceptsUnsignedThinking: provider.acceptsUnsignedThinking ?? (specifier.provider == "deepseek"), replayScope: replayScope, routeEpoch: routeEpoch)
      case .codex:
        throw .invalidInput(status: 422, body: CatalogError.invalidOIDCDialect(provider: specifier.provider).description)
      }
      var resolved = ResolvedModel(specifier: specifier, endpoint: endpoint, budget: model.budget(provider.dialect), transport: provider.transport ?? .sse, replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
      resolved.socketIdentity = SocketRegistryIdentity(provider: specifier.provider, model: specifier.model, configuration: provider, credential: .apiKey(token), replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
      return resolved
    }
    let held: CredentialBinding?
    do {
      held = try await credentials.resolveBinding(specifier.provider)
    } catch ChatGPTAuthError.loginRequired {
      throw .credentialRefreshRefused(provider: specifier.provider)
    } catch let error as ChatGPTAuthError {
      throw error.asInferenceError
    } catch {
      throw InferenceError.normalize(error)
    }
    guard let binding = held else {
      throw .invalidInput(
        status: 401,
        body: CatalogError.missingCredential(provider: specifier.provider).description,
      )
    }
    let credential = binding.credential
    let bindingIdentity = provider.bindingIdentity(providerID: specifier.provider, credentialEpoch: binding.identityEpoch)
    let replayScope = provider.effectiveOpaqueReplay == .affine && binding.permitsOpaqueReplay ? bindingIdentity : nil
    let cacheKey = replayCacheKey(session: session, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
    let endpoint: any ModelEndpoint
    switch (provider.dialect, credential) {
    case (.claude, .claudeCodeOAuth), (.claude, .chatGPT):
      throw .invalidInput(status: 401, body: CatalogError.claudeAPIKeyRequired(provider: specifier.provider).description)
    case let (.claude, .apiKey(key)):
      endpoint = AnthropicEndpoint(model: specifier.model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: provider.baseURL, apiKey: key, promptCache: .oneHour, acceptsUnsignedThinking: provider.acceptsUnsignedThinking ?? false)
    case let (.anthropic, .apiKey(key)) where specifier.provider == "deepseek":
      endpoint = DeepSeekAnthropicEndpoint(model: specifier.model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: provider.baseURL, apiKey: key, acceptsUnsignedThinking: provider.acceptsUnsignedThinking ?? true)
    case let (.anthropic, .apiKey(key)):
      endpoint = AnthropicEndpoint(model: specifier.model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: provider.baseURL, apiKey: key, promptCache: .oneHour, acceptsUnsignedThinking: provider.acceptsUnsignedThinking ?? false)
    case let (.responses, .apiKey(key)):
      endpoint = OpenAIGPTEndpoint(
        model: specifier.model,
        replayScope: replayScope,
        routeEpoch: routeEpoch,
        baseURL: provider.baseURL,
        apiKey: key,
        promptCacheKey: cacheKey,
      )
    case let (.codex, .chatGPT(accessToken, accountID)):
      endpoint = OpenAICodexEndpoint(
        model: specifier.model,
        replayScope: replayScope,
        routeEpoch: routeEpoch,
        baseURL: provider.baseURL,
        jwt: accessToken,
        chatgptAccountID: accountID,
        sessionID: cacheKey,
        originator: provider.originator ?? "wuhu",
        receiveResponseHeaders: { headers in
          await receiveCodexResponseHeaders(specifier.provider, headers)
        },
      )
    case (.codex, .apiKey), (.anthropic, .chatGPT), (.responses, .chatGPT),
         (.anthropic, .claudeCodeOAuth), (.responses, .claudeCodeOAuth), (.codex, .claudeCodeOAuth):
      throw .invalidInput(
        status: 401,
        body: CatalogError.credentialMismatch(provider: specifier.provider).description,
      )
    }
    var resolved = ResolvedModel(specifier: specifier, endpoint: endpoint, budget: model.budget(provider.dialect), transport: provider.transport ?? .sse, replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
    resolved.socketIdentity = SocketRegistryIdentity(provider: specifier.provider, model: specifier.model, configuration: provider, credential: credential, replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
    return resolved
  }
}

extension ChatGPTAuthError {
  var asInferenceError: InferenceError {
    switch self {
    case let .unreachable(_, kind):
      .transport(kind)
    case .protocolFailure:
      .transient(status: nil, body: description)
    case .loginRequired, .authorizationTimedOut:
      .invalidInput(status: 401, body: description)
    }
  }
}

extension CatalogError {
  public var code: String {
    switch self {
    case .credentialLoginRequired: "credentialLoginRequired"
    case .modelRouteInvalid: "modelRouteInvalid"
    case .noUsableMembers: "modelGroupUnavailable"
    case .unsupportedTarget: "unsupportedTarget"
    case .invalidDocument, .invalidGroupsDocument, .invalidGroup, .unknownGroup, .groupMember, .invalidCapacity: "modelGroupConfiguration"
    default: "invalidArgument"
    }
  }
}
