#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import Dependencies

public struct CredentialsStoreError: Error, CustomStringConvertible, Sendable {
  public let message: String

  public var description: String { message }
}

public enum UserConfig {
  public static func directory(environment: [String: String]) throws -> URL {
    if let override = environment["WUHU_CONFIG_DIR"] {
      guard !override.isEmpty else {
        throw CredentialsStoreError(message: "WUHU_CONFIG_DIR is set but empty")
      }
      return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    guard let home = environment["HOME"], !home.isEmpty else {
      throw CredentialsStoreError(message: "HOME is not set; cannot locate ~/.wuhu")
    }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".wuhu", isDirectory: true).standardizedFileURL
  }
}

public struct CredentialsStore: Sendable {
  public let directory: URL
  public let spaceID: String
  private let storage: PrivateFile

  public init(configDirectory: URL, spaceID: String) {
    directory = configDirectory.appendingPathComponent("credentials", isDirectory: true)
    self.spaceID = spaceID
    storage = PrivateFile(directory: directory, stem: spaceID)
  }

  public var file: URL {
    storage.url
  }

  public func load() async throws -> CredentialsFile {
    guard let data = try storage.read() else { return .empty }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(CredentialsFile.self, from: data)
    } catch {
      throw CredentialsStoreError(message: """
      malformed credentials store \(file.path): \(error)
      fix or remove it, then re-add credentials: wuhu auth set/login
      """)
    }
  }

  public func save(_ contents: CredentialsFile) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    try storage.replace(with: try encoder.encode(contents))
  }

  public func update(_ mutate: @Sendable (inout CredentialsFile) -> Void) async throws {
    try await storage.withLock {
      var contents = try await load()
      let previous = contents.providers
      mutate(&contents)
      for provider in Set(previous.keys).union(contents.providers.keys) where previous[provider] != contents.providers[provider] {
        contents.identityEpochs[provider] = nil
      }
      try await save(contents)
    }
  }

  public func replace(providerID: String, credential: StoredCredential?) async throws {
    try await update {
      $0.providers[providerID] = credential
      $0.identityEpochs[providerID] = nil
    }
  }

  func binding(providerID: String, environmentKey: String?) async throws -> CredentialBinding? {
    try await storage.withLock {
      var contents = try await load()
      let previous = contents
      if let environmentKey {
        let identity = contents.identity(for: .apiKey(environmentKey), providerID: providerID, environment: true)
        if contents != previous { try await save(contents) }
        return CredentialBinding(credential: .apiKey(environmentKey), identityEpoch: identity.epoch)
      }
      // Returning from an environment override must not revive an older affinity.
      if contents.environmentIdentityEpochs.removeValue(forKey: providerID) != nil {
        contents.identityEpochs[providerID] = nil
      }
      guard var stored = contents.providers[providerID] else {
        if contents != previous { try await save(contents) }
        return nil
      }
      var identity = contents.identity(for: stored, providerID: providerID, environment: false)
      if case let .chatGPTOAuth(tokens) = stored {
        @Dependency(\.date.now) var now
        if tokens.needsRefresh(at: now) {
          let refreshed = try await ChatGPTAuth.refresh(tokens)
          stored = .chatGPTOAuth(refreshed)
          if refreshed.accountID != tokens.accountID { identity.epoch = UUID().uuidString }
          contents.providers[providerID] = stored
          contents.identityEpochs[providerID] = CredentialIdentity(epoch: identity.epoch, fingerprint: contents.fingerprint(stored))
        }
      }
      if contents != previous { try await save(contents) }
      let credential: ProviderCredential = switch stored {
      case let .apiKey(key): .apiKey(key)
      case let .chatGPTOAuth(tokens): .chatGPT(accessToken: tokens.accessToken, accountID: tokens.accountID)
      }
      return CredentialBinding(credential: credential, identityEpoch: identity.epoch)
    }
  }
}

extension CredentialsFile {
  mutating func identity(for credential: StoredCredential, providerID: String, environment: Bool) -> CredentialIdentity {
    let fingerprint = fingerprint(credential)
    let previous = environment ? environmentIdentityEpochs[providerID] : identityEpochs[providerID]
    let identity = previous?.fingerprint == fingerprint ? previous! : CredentialIdentity(epoch: UUID().uuidString, fingerprint: fingerprint)
    if environment { environmentIdentityEpochs[providerID] = identity }
    else { identityEpochs[providerID] = identity }
    return identity
  }

  mutating func fingerprint(_ credential: StoredCredential) -> String {
    if identityKey == nil { identityKey = UUID().uuidString + UUID().uuidString }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(credential)
    let key = SymmetricKey(data: Data(identityKey!.utf8))
    return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String($0, radix: 16).leftPaddedHex }.joined()
  }
}

private extension String {
  var leftPaddedHex: String { count == 1 ? "0" + self : self }
}
