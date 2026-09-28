import Foundation
import JSONValue
import OrderedCollections

actor SecretVault {
  struct UnknownSecret: Error {
    let name: String
  }

  struct CorruptVault: Error {}

  struct Resolved: Sendable {
    let env: [String: String]
    let maskedValues: [String]
  }

  private let file: URL

  init(stateDirectory: URL) {
    file = stateDirectory.appendingPathComponent("vault.json")
  }

  func set(name: String, value: String) throws {
    var secrets = try load()
    secrets[name] = value
    try persist(secrets)
  }

  func remove(name: String) throws {
    var secrets = try load()
    secrets.removeValue(forKey: name)
    try persist(secrets)
  }

  func names() throws -> [String] {
    try load().keys.sorted()
  }

  func resolve(_ mapping: [String: String]) throws -> Resolved {
    let secrets = try load()
    var env: [String: String] = [:]
    var masked: Set<String> = []
    for (envName, secretName) in mapping {
      guard let value = secrets[secretName] else { throw UnknownSecret(name: secretName) }
      env[envName] = value
      // An empty value would mask every position of the output; inject it but
      // do not register it for redaction.
      if !value.isEmpty { masked.insert(value) }
    }
    return Resolved(env: env, maskedValues: masked.sorted())
  }

  private func load() throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    let text = try String(contentsOf: file, encoding: .utf8)
    guard let value = JSONValue.parse(text), case let .object(fields) = value else { throw CorruptVault() }
    var secrets: [String: String] = [:]
    for (name, field) in fields {
      guard case let .string(secret) = field else { throw CorruptVault() }
      secrets[name] = secret
    }
    return secrets
  }

  private func persist(_ secrets: [String: String]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    let fields = OrderedDictionary(uniqueKeysWithValues: secrets.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) })
    let json = JSONValue.object(fields).jsonString()
    guard FileManager.default.createFile(
      atPath: file.path,
      contents: Data(json.utf8),
      attributes: [.posixPermissions: 0o600],
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
