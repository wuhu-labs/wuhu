#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum SecretError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidName(String)
  case emptyValue
  case unknown(String)
  case corrupt(String)
  case invalidGroup(String)

  public var description: String {
    switch self {
    case let .invalidName(name):
      "invalid secret name '\(name)': use up to 128 letters, digits and underscores, not starting with a digit"
    case .emptyValue:
      "a secret's value cannot be empty"
    case let .unknown(name):
      "no secret named \(name)"
    case let .corrupt(path):
      "malformed secret store \(path); fix or remove it"
    case let .invalidGroup(group):
      "invalid group '\(group)'"
    }
  }
}

// A space's secrets, one file per group: ~/.wuhu/secrets/<spaceID>/<group>.json.
public struct SpaceSecretStores: Sendable {
  public let configDirectory: URL
  public let spaceID: String

  public init(configDirectory: URL, spaceID: String) {
    self.configDirectory = configDirectory
    self.spaceID = spaceID
  }

  public func group(_ group: String) throws(SecretError) -> SpaceSecrets {
    try SpaceSecrets(configDirectory: configDirectory, spaceID: spaceID, group: group)
  }

  /// The single-file store from before groups. While it exists the space's
  /// secrets have not been moved into `shared`.
  public var flatFile: URL {
    configDirectory.appendingPathComponent("secrets", isDirectory: true).appendingPathComponent("\(spaceID).json")
  }

  public var needsMove: Bool {
    FileManager.default.fileExists(atPath: flatFile.path)
  }

  /// The folder holding one file per group.
  public var directory: URL {
    configDirectory.appendingPathComponent("secrets", isDirectory: true).appendingPathComponent(spaceID, isDirectory: true)
  }

  /// Makes an existing store folder owner-only: one made by hand (a plain
  /// `mkdir` is 0755) is tightened to 0700. A missing folder is left for the
  /// first write, which creates it 0700.
  public func tightenDirectory() throws {
    try tightenToOwnerOnly(directory.path)
  }
}

public struct SpaceSecrets: Sendable {
  private let storage: PrivateFile

  public init(configDirectory: URL, spaceID: String, group: String) throws(SecretError) {
    try Self.validate(group: group)
    storage = PrivateFile(
      directory: configDirectory.appendingPathComponent("secrets", isDirectory: true)
        .appendingPathComponent(spaceID, isDirectory: true),
      stem: group,
    )
  }

  // A group id names a file, so only the characters a group id is made of.
  public static func validate(group: String) throws(SecretError) {
    let bytes = Array(group.utf8)
    guard (1 ... 128).contains(bytes.count), bytes[0] != UInt8(ascii: "-"),
          bytes.allSatisfy({ isDigit($0) || isLetter($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") })
    else { throw .invalidGroup(group) }
  }

  public var file: URL {
    storage.url
  }

  public static func validate(_ name: String) throws(SecretError) {
    let bytes = Array(name.utf8)
    guard (1 ... 128).contains(bytes.count), !isDigit(bytes[0]),
          bytes.allSatisfy({ isDigit($0) || isLetter($0) || $0 == UInt8(ascii: "_") })
    else { throw .invalidName(name) }
  }

  public func set(_ name: String, to value: String) async throws {
    try Self.validate(name)
    guard !value.isEmpty else { throw SecretError.emptyValue }
    try await storage.withLock {
      var secrets = try load()
      secrets[name] = value
      try save(secrets)
    }
  }

  public func remove(_ name: String) async throws {
    try await storage.withLock {
      var secrets = try load()
      guard secrets.removeValue(forKey: name) != nil else { throw SecretError.unknown(name) }
      try save(secrets)
    }
  }

  public func names() async throws -> [String] {
    try load().keys.sorted()
  }

  public func value(of name: String) async throws -> String {
    guard let value = try load()[name] else { throw SecretError.unknown(name) }
    return value
  }

  private func load() throws -> [String: String] {
    guard let data = try storage.read() else { return [:] }
    do {
      return try JSONDecoder().decode([String: String].self, from: data)
    } catch {
      throw SecretError.corrupt(file.path)
    }
  }

  private func save(_ secrets: [String: String]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try storage.replace(with: try encoder.encode(secrets))
  }
}

private func isDigit(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
}

private func isLetter(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte | 0x20)
}
