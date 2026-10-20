import struct Credentials.SpaceSecrets
import Dependencies
import JSONValue
import SpaceClient
import struct SpaceContract.SecretsOutput
import Synchronization

// A script names a secret by a placeholder and never holds its value: the
// value replaces the placeholder only in the request fetch sends, and every
// value sent so far is masked in whatever comes back into the script or goes
// out of it.
//
// A name resolves in the session's own group; another group the session's
// group reads is named explicitly, and its placeholder carries it as
// `wuhu-secret.<group>:<name>.<suffix>`. The secret routes answer as the
// session, so their refusals are the script's errors.
final class ScriptSecrets: Sendable {
  private static let prefix = Array("wuhu-secret.".utf8)
  private static let mask = Array("***".utf8)

  private let client: SpaceClient
  private let suffix: [UInt8]
  private let sent = Mutex<[[UInt8]]>([])

  init(client: SpaceClient) {
    @Dependency(\.uuid) var uuid
    self.client = client
    suffix = Array(".\(uuid().uuidString.lowercased().prefix(8))".utf8)
  }

  func placeholder(for name: String, group: String? = nil) throws -> String {
    try SpaceSecrets.validate(name)
    var token = Array(name.utf8)
    if let group {
      try SpaceSecrets.validate(group: group)
      token = Array(group.utf8) + [UInt8(ascii: ":")] + token
    }
    return String(decoding: Self.prefix + token + suffix, as: UTF8.self)
  }

  func names(in group: String?) async throws -> [String] {
    if let group { try SpaceSecrets.validate(group: group) }
    do {
      let output: SecretsOutput = try await client.api(.get, queryPath("/v1/secret", [("group", group)]))
      return output.names
    } catch { throw scriptFailure(error) }
  }

  func set(_ name: String, to value: String) async throws {
    try SpaceSecrets.validate(name)
    do {
      _ = try await client.api(.put, "/v1/secret/\(pathSegment(name))", body: .object(["value": .string(value)])) as JSONValue
    } catch { throw scriptFailure(error) }
  }

  func remove(_ name: String) async throws {
    try SpaceSecrets.validate(name)
    do {
      _ = try await client.api(.delete, "/v1/secret/\(pathSegment(name))") as JSONValue
    } catch { throw scriptFailure(error) }
  }

  func reveal(_ text: String) async throws -> String {
    String(decoding: try await reveal(Array(text.utf8)), as: UTF8.self)
  }

  func reveal(_ bytes: [UInt8]) async throws -> [UInt8] {
    guard bytes.firstRange(of: Self.prefix) != nil else { return bytes }
    var values: [String: [UInt8]] = [:]
    var output: [UInt8] = []
    var rest = bytes[...]
    while let found = rest.firstRange(of: Self.prefix) {
      output += rest[..<found.lowerBound]
      guard let (group, name, end) = placeholder(in: bytes, at: found.upperBound) else {
        output += rest[found]
        rest = rest[found.upperBound...]
        continue
      }
      let key = (group.map { $0 + ":" } ?? "") + name
      if values[key] == nil {
        let value = Array(try await value(of: name, in: group).utf8)
        values[key] = value
        protect(String(decoding: value, as: UTF8.self))
      }
      output += values[key]!
      rest = bytes[end...]
    }
    return output + rest
  }

  private func value(of name: String, in group: String?) async throws -> String {
    struct Value: Decodable { let value: String }
    do {
      let output: Value = try await client.api(.get, queryPath("/v1/secret/\(pathSegment(name))", [("group", group)]))
      return output.value
    } catch { throw scriptFailure(error) }
  }

  // True when the bytes hold a placeholder of this run, which only fetch may
  // resolve.
  func carriesPlaceholder(_ bytes: [UInt8]) -> Bool {
    var rest = bytes[...]
    while let found = rest.firstRange(of: Self.prefix) {
      if placeholder(in: bytes, at: found.upperBound) != nil { return true }
      rest = bytes[found.upperBound...]
    }
    return false
  }

  func protect(_ text: String) {
    let value = Array(text.utf8)
    guard !value.isEmpty else { return }
    sent.withLock { sent in
      if !sent.contains(value) { sent.append(value) }
      sent.sort { $0.count > $1.count }
    }
  }

  func mask(_ text: String) -> String {
    String(decoding: mask(Array(text.utf8)), as: UTF8.self)
  }

  func mask(_ bytes: [UInt8]) -> [UInt8] {
    sent.withLock { $0 }.reduce(bytes) { masked, value in
      guard masked.firstRange(of: value) != nil else { return masked }
      var output: [UInt8] = []
      var rest = masked[...]
      while let found = rest.firstRange(of: value) {
        output += rest[..<found.lowerBound] + Self.mask
        rest = rest[found.upperBound...]
      }
      return output + rest
    }
  }

  private func placeholder(in bytes: [UInt8], at start: Int) -> (group: String?, name: String, end: Int)? {
    var cursor = start
    while cursor < bytes.count, isNameByte(bytes[cursor]) || bytes[cursor] == UInt8(ascii: "-") || bytes[cursor] == UInt8(ascii: ":") {
      cursor += 1
    }
    guard cursor > start, bytes[cursor...].starts(with: suffix) else { return nil }
    let parts = bytes[start ..< cursor].split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
    let name = parts.last!
    guard parts.count <= 2, !name.isEmpty, name.allSatisfy(isNameByte) else { return nil }
    let group = parts.count == 2 ? String(decoding: parts[0], as: UTF8.self) : nil
    return (group, String(decoding: name, as: UTF8.self), cursor + suffix.count)
  }
}

private func isNameByte(_ byte: UInt8) -> Bool {
  byte == UInt8(ascii: "_")
    || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte | 0x20)
}
