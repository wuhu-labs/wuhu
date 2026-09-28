#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension ProviderCatalog {
  public static let codexProviderID: String = "codex"
  public static let openAIProviderID: String = "openai"

  public func resolveTranscriber() async -> (any Transcriber)? {
    if case let .chatGPT(accessToken, accountID)? = try? await credentials.resolve(Self.codexProviderID) {
      let provider = document.providers[Self.codexProviderID]
      return CodexTranscriber(
        baseURL: provider.map { Self.chatGPTBackendRoot($0.baseURL) } ?? CodexTranscriber.defaultBaseURL,
        accessToken: accessToken,
        accountID: accountID,
        originator: provider?.originator ?? "wuhu",
      )
    }
    if case let .apiKey(key)? = try? await credentials.resolve(Self.openAIProviderID) {
      return OpenAITranscriber(
        baseURL: document.providers[Self.openAIProviderID]?.baseURL ?? OpenAITranscriber.defaultBaseURL,
        apiKey: key,
      )
    }
    return nil
  }

  // The codex chat models sit under /backend-api/codex; dictation is its sibling
  // at /backend-api/transcribe, so the model sheet's base URL is one level too deep.
  static func chatGPTBackendRoot(_ codexBaseURL: URL) -> URL {
    codexBaseURL.lastPathComponent == "codex" ? codexBaseURL.deletingLastPathComponent() : codexBaseURL
  }
}
