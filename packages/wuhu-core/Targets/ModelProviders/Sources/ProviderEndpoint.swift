import enum Credentials.ProviderCredential
import WuhuAI

extension ModelsDocument.Provider {
  public func endpoint(
    providerID: String,
    model: String,
    credential: ProviderCredential,
    replayScope: String?,
    routeEpoch: String,
    cacheKey: String?,
    receiveCodexResponseHeaders: @escaping @Sendable ([String: String]) async -> Void = { _ in },
  ) throws(CatalogError) -> any ModelEndpoint {
    switch (dialect, credential) {
    case let (.anthropic, .apiKey(token)) where auth == .oidc:
      OIDCAnthropicEndpoint(model: model, baseURL: baseURL, token: token, deepSeek: providerID == "deepseek", replayScope: replayScope, routeEpoch: routeEpoch)
    case (.codex, _) where auth == .oidc:
      throw .invalidOIDCDialect(provider: providerID)
    case let (.anthropic, .apiKey(key)) where providerID == "deepseek":
      DeepSeekAnthropicEndpoint(model: model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: baseURL, apiKey: key)
    case let (.anthropic, .apiKey(key)):
      AnthropicEndpoint(model: model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: baseURL, apiKey: key, promptCache: .oneHour)
    case let (.responses, .apiKey(key)):
      OpenAIGPTEndpoint(model: model, replayScope: replayScope, routeEpoch: routeEpoch, baseURL: baseURL, apiKey: key, promptCacheKey: cacheKey)
    case let (.codex, .chatGPT(accessToken, accountID)):
      OpenAICodexEndpoint(
        model: model,
        replayScope: replayScope,
        routeEpoch: routeEpoch,
        baseURL: baseURL,
        jwt: accessToken,
        chatgptAccountID: accountID,
        sessionID: cacheKey,
        originator: originator ?? "wuhu",
        receiveResponseHeaders: receiveCodexResponseHeaders,
      )
    case (.codex, .apiKey), (.anthropic, .chatGPT), (.responses, .chatGPT):
      throw .credentialMismatch(provider: providerID)
    }
  }
}
