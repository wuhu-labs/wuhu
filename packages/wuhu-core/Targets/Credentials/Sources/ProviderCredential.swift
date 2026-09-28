#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum ProviderCredential: Sendable, Hashable {
  case apiKey(String)
  case chatGPT(accessToken: String, accountID: String)
  case claudeCodeOAuth(String)
}

public struct CredentialResolver: Sendable {
  public var resolve: @Sendable (String) async throws -> ProviderCredential?

  public init(resolve: @escaping @Sendable (String) async throws -> ProviderCredential?) {
    self.resolve = resolve
  }

  public static func environmentAPIKey(_ providerID: String) -> String? {
    let name = providerID.uppercased().replacingOccurrences(of: "-", with: "_") + "_API_KEY"
    return ProcessInfo.processInfo.environment[name]
  }

  public static let environmentOnly: CredentialResolver = CredentialResolver { providerID in
    environmentAPIKey(providerID).map(ProviderCredential.apiKey)
  }

  public static let unavailable: CredentialResolver = CredentialResolver { _ in nil }

  public static func live(store: CredentialsStore) -> CredentialResolver {
    CredentialResolver { providerID in
      if let key = environmentAPIKey(providerID) {
        return .apiKey(key)
      }
      switch try await store.load().providers[providerID] {
      case nil:
        return nil
      case let .apiKey(key):
        return .apiKey(key)
      case let .claudeCodeOAuth(token):
        return .claudeCodeOAuth(token)
      case let .chatGPTOAuth(tokens):
        let fresh = try await store.refreshedTokens(providerID: providerID, cached: tokens)
        return .chatGPT(accessToken: fresh.accessToken, accountID: fresh.accountID)
      }
    }
  }
}
