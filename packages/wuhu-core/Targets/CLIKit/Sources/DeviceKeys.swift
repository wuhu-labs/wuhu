#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto

enum Ed25519KeyFile {
  static func read(_ file: URL, hint: String) throws -> Curve25519.Signing.PrivateKey? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    try requireOwnerOnly(file.deletingLastPathComponent(), mode: "700")
    try requireOwnerOnly(file, mode: "600")
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), raw.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
      throw CLIError(message: "malformed key \(file.path); \(hint)")
    }
    return key
  }

  static func write(_ key: Curve25519.Signing.PrivateKey, to file: URL) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    // createDirectory applies attributes only on creation; re-tighten a
    // pre-existing loose directory.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let created = FileManager.default.createFile(
      atPath: file.path,
      contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
      attributes: [.posixPermissions: 0o600],
    )
    guard created else {
      throw CLIError(message: "cannot write \(file.path)")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  private static func requireOwnerOnly(_ item: URL, mode: String) throws {
    let permissions = posixMode(try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions])
    guard let permissions, permissions & 0o077 == 0 else {
      throw CLIError(message: """
      refusing \(item.path): permissions are \(permissions.map { String($0, radix: 8) } ?? "unreadable"), expected \(mode)
      fix with: chmod \(mode) \(item.path)
      """)
    }
  }
}

// space identities are spc_<32 lowercase alnum>; duplicated here (rather than
// depending on SpaceCore's SpaceIdentity) because CLIKit stays off SpaceCore's
// GRDB-linked production dependency for this one shape check.
func isValidSpaceIdentity(_ candidate: String) -> Bool {
  let prefix = "spc_"
  guard candidate.hasPrefix(prefix) else { return false }
  let suffix = candidate.dropFirst(prefix.count)
  guard suffix.count == 32 else { return false }
  return suffix.allSatisfy { $0.isASCII && (("a" ... "z").contains($0) || ("0" ... "9").contains($0)) }
}

// One keypair per (device x space), keyed by the space's opaque identity:
// keys are never reused across spaces and never leave this directory.
struct DeviceKeyStore {
  let directory: URL

  init(environment: [String: String]) throws {
    directory = try ServerTrust.userConfigDirectory(environment: environment)
      .appendingPathComponent("keys", isDirectory: true)
  }

  func keyFile(space identity: String) -> URL {
    // The identity becomes a file name; anything but the exact spc_<32 alnum>
    // shape could traverse outside the keys directory.
    precondition(isValidSpaceIdentity(identity), "space identities are spc_<32 lowercase alnum>, got \(identity)")
    return directory.appendingPathComponent(identity + ".key")
  }

  func load(space identity: String) throws -> Curve25519.Signing.PrivateKey? {
    try Ed25519KeyFile.read(keyFile(space: identity), hint: "delete it to enroll this device afresh")
  }

  func loadOrCreate(space identity: String) throws -> Curve25519.Signing.PrivateKey {
    if let existing = try load(space: identity) {
      return existing
    }
    let key = Curve25519.Signing.PrivateKey()
    try Ed25519KeyFile.write(key, to: keyFile(space: identity))
    return key
  }
}
