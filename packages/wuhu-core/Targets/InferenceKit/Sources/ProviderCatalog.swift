import enum Credentials.ChatGPTAuthError
import struct Credentials.CredentialResolver
import enum Credentials.ProviderCredential
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ContextBudget
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionID
import WuhuAI

public enum CatalogError: Error, Equatable, Sendable, CustomStringConvertible {
  case unknownProvider(String)
  case unknownModel(provider: String, model: String)
  case unknownEffort(provider: String, model: String, effort: String)
  case missingCredential(provider: String)
  case credentialMismatch(provider: String)
  case invalidTransport(provider: String)

  public var description: String {
    switch self {
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
  var socketIdentity: SocketRegistryIdentity?

  public init(specifier: ModelSpecifier, endpoint: any ModelEndpoint, budget: ContextBudget, transport: ModelsDocument.Transport = .sse) {
    self.specifier = specifier
    self.endpoint = endpoint
    self.budget = budget
    self.transport = transport
  }
}

public struct ProviderCatalog: Sendable {
  public var document: ModelsDocument
  public var credentials: CredentialResolver
  private let receiveCodexResponseHeaders: @Sendable (String, [String: String]) async -> Void

  public init(
    document: ModelsDocument,
    credentials: CredentialResolver,
    receiveCodexResponseHeaders: @escaping @Sendable (String, [String: String]) async -> Void = { _, _ in },
  ) {
    self.document = document
    self.credentials = credentials
    self.receiveCodexResponseHeaders = receiveCodexResponseHeaders
  }

  @discardableResult
  public func validate(_ specifier: ModelSpecifier) throws -> ModelsDocument.Model {
    guard let provider = document.providers[specifier.provider] else {
      throw CatalogError.unknownProvider(specifier.provider)
    }
    guard provider.transport != .websocket || provider.dialect == .responses || provider.dialect == .codex else {
      throw CatalogError.invalidTransport(provider: specifier.provider)
    }
    guard let model = provider.models[specifier.model] else {
      throw CatalogError.unknownModel(provider: specifier.provider, model: specifier.model)
    }
    guard model.efforts.contains(specifier.effort) else {
      throw CatalogError.unknownEffort(
        provider: specifier.provider,
        model: specifier.model,
        effort: specifier.effort,
      )
    }
    return model
  }

  public func defaultSpecifier(provider providerID: String, model modelName: String) throws -> ModelSpecifier {
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
    guard provider.dialect != .claude else {
      throw .invalidInput(status: 422, body: "provider \(specifier.provider) is run by the Claude Code executor, never by kernel inference")
    }
    let held: ProviderCredential?
    do {
      held = try await credentials.resolve(specifier.provider)
    } catch let error as ChatGPTAuthError {
      throw error.asInferenceError
    } catch {
      throw InferenceError.normalize(error)
    }
    guard let credential = held else {
      throw .invalidInput(
        status: 401,
        body: CatalogError.missingCredential(provider: specifier.provider).description,
      )
    }
    let endpoint: any ModelEndpoint
    switch (provider.dialect, credential) {
    case (.claude, _):
      throw .invalidInput(status: 422, body: "provider \(specifier.provider) is run by the Claude Code executor, never by kernel inference")
    case let (.anthropic, .apiKey(key)) where specifier.provider == "deepseek":
      endpoint = DeepSeekAnthropicEndpoint(model: specifier.model, baseURL: provider.baseURL, apiKey: key)
    case let (.anthropic, .apiKey(key)):
      endpoint = AnthropicEndpoint(model: specifier.model, baseURL: provider.baseURL, apiKey: key, promptCache: .oneHour)
    case let (.responses, .apiKey(key)):
      endpoint = OpenAIGPTEndpoint(
        model: specifier.model,
        baseURL: provider.baseURL,
        apiKey: key,
        promptCacheKey: session.rawValue,
      )
    case let (.codex, .chatGPT(accessToken, accountID)):
      endpoint = OpenAICodexEndpoint(
        model: specifier.model,
        baseURL: provider.baseURL,
        jwt: accessToken,
        chatgptAccountID: accountID,
        sessionID: session.rawValue,
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
    var resolved = ResolvedModel(specifier: specifier, endpoint: endpoint, budget: model.budget(provider.dialect), transport: provider.transport ?? .sse)
    resolved.socketIdentity = SocketRegistryIdentity(provider: specifier.provider, model: specifier.model, configuration: provider, credential: credential)
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
