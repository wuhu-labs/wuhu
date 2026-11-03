import enum Credentials.ChatGPTAuthError
import struct Credentials.CredentialBinding
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
import ModelProviders
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ContextBudget
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionID
import WuhuAI

public struct ResolvedModel: Sendable {
  public var specifier: ModelSpecifier
  public var endpoint: any ModelEndpoint
  public var budget: ContextBudget
  public var transport: ModelsDocument.Transport
  public var replayScope: String?
  public var bindingIdentity: String
  public var routeEpoch: String
  var socketIdentity: SocketRegistryIdentity?

  /// The model is Claude, decided from its model id whatever the host or
  /// dialect (``ModelSpecifier/isClaudeModel(_:)``).
  public var isClaude: Bool { ModelSpecifier.isClaudeModel(specifier.model) }

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
  public func validate(_ specifier: ModelSpecifier) throws(CatalogError) -> ModelsDocument.Model {
    try document.validated(provider: specifier.provider, model: specifier.model, effort: specifier.effort).model
  }

  public func defaultSpecifier(provider providerID: String, model modelName: String) throws(CatalogError) -> ModelSpecifier {
    if let error = document.providerErrors[providerID] { throw error }
    if document.groupErrors[providerID] != nil || document.groups[providerID] != nil { throw CatalogError.unsupportedTarget(providerID) }
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
    } catch {
      throw .invalidInput(status: 422, body: error.description)
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
        if case .other = failure { throw .oidcSigningFailed(provider: specifier.provider) }
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
      case .anthropic:
        endpoint = OIDCAnthropicEndpoint(model: specifier.model, baseURL: provider.baseURL, token: token, deepSeek: specifier.provider == "deepseek", replayScope: replayScope, routeEpoch: routeEpoch)
      case .codex:
        throw .invalidInput(status: 422, body: CatalogError.invalidOIDCDialect(provider: specifier.provider).description)
      }
      var resolved = ResolvedModel(specifier: specifier, endpoint: endpoint, budget: model.budget(images: provider.images), transport: provider.transport ?? .sse, replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
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
    do {
      endpoint = try provider.endpoint(providerID: specifier.provider, model: specifier.model, credential: credential, replayScope: replayScope, routeEpoch: routeEpoch, cacheKey: cacheKey) { headers in
        await receiveCodexResponseHeaders(specifier.provider, headers)
      }
    } catch {
      throw .invalidInput(status: 401, body: error.description)
    }
    var resolved = ResolvedModel(specifier: specifier, endpoint: endpoint, budget: model.budget(images: provider.images), transport: provider.transport ?? .sse, replayScope: replayScope, bindingIdentity: bindingIdentity, routeEpoch: routeEpoch)
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
