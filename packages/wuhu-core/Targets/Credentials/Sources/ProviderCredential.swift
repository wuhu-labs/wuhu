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

public struct CredentialBinding: Sendable {
  public var credential: ProviderCredential
  public var identityEpoch: String
  public var permitsOpaqueReplay: Bool

  public init(credential: ProviderCredential, identityEpoch: String, permitsOpaqueReplay: Bool = true) {
    self.credential = credential
    self.identityEpoch = identityEpoch
    self.permitsOpaqueReplay = permitsOpaqueReplay
  }
}

public struct CredentialResolver: Sendable {
  public let resolveBinding: @Sendable (String) async throws -> CredentialBinding?

  public func resolve(_ providerID: String) async throws -> ProviderCredential? {
    try await resolveBinding(providerID)?.credential
  }

  public init(resolve: @escaping @Sendable (String) async throws -> ProviderCredential?) {
    let identities = TransientCredentialIdentities()
    resolveBinding = { provider in
      guard let credential = try await resolve(provider) else { return nil }
      return await identities.binding(provider: provider, credential: credential)
    }
  }

  private init(resolveBinding: @escaping @Sendable (String) async throws -> CredentialBinding?) {
    self.resolveBinding = resolveBinding
  }

  public static func bound(_ resolve: @escaping @Sendable (String) async throws -> CredentialBinding?) -> Self {
    Self(resolveBinding: resolve)
  }

  public static func environmentAPIKey(_ providerID: String) -> String? {
    let name = providerID.uppercased().replacingOccurrences(of: "-", with: "_") + "_API_KEY"
    return ProcessInfo.processInfo.environment[name]
  }

  public static let environmentOnly: CredentialResolver = {
    let identities = TransientCredentialIdentities(permitsOpaqueReplay: true)
    return .bound { providerID in
      guard let key = environmentAPIKey(providerID) else {
        await identities.remove(provider: providerID)
        return nil
      }
      return await identities.binding(provider: providerID, credential: .apiKey(key))
    }
  }()

  public static let unavailable: CredentialResolver = CredentialResolver(resolve: { _ in nil })

  public static func live(store: CredentialsStore, allowEnvironment: Bool = true) -> CredentialResolver {
    CredentialResolver(resolveBinding: { providerID in
      let environmentKey = allowEnvironment ? environmentAPIKey(providerID) : nil
      return try await store.binding(providerID: providerID, environmentKey: environmentKey)
    })
  }
}

private actor TransientCredentialIdentities {
  private let permitsOpaqueReplay: Bool
  private var current: [String: CredentialBinding] = [:]

  init(permitsOpaqueReplay: Bool = false) {
    self.permitsOpaqueReplay = permitsOpaqueReplay
  }

  func remove(provider: String) {
    current.removeValue(forKey: provider)
  }

  func binding(provider: String, credential: ProviderCredential) -> CredentialBinding {
    if let binding = current[provider], binding.credential == credential { return binding }
    let binding = CredentialBinding(credential: credential, identityEpoch: UUID().uuidString, permitsOpaqueReplay: permitsOpaqueReplay)
    current[provider] = binding
    return binding
  }
}
