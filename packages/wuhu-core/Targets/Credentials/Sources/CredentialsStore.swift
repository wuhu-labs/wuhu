#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

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
      mutate(&contents)
      try await save(contents)
    }
  }

  // Refresh tokens rotate: whoever refreshes must persist before anyone else
  // tries, so refresh runs under the cross-process lock, re-reading the store
  // first to adopt a rotation another process already performed.
  public func refreshedTokens(providerID: String, cached: ChatGPTTokens) async throws -> ChatGPTTokens {
    @Dependency(\.date.now) var now
    guard cached.needsRefresh(at: now) else { return cached }
    return try await storage.withLock {
      var contents = try await load()
      let current: ChatGPTTokens
      if case let .chatGPTOAuth(stored) = contents.providers[providerID] {
        current = stored
      } else {
        current = cached
      }
      guard current.needsRefresh(at: now) else { return current }
      let refreshed = try await ChatGPTAuth.refresh(current)
      contents.providers[providerID] = .chatGPTOAuth(refreshed)
      try await save(contents)
      return refreshed
    }
  }
}
