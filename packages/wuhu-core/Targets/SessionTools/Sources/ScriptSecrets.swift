import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Dependencies
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import Synchronization

// A script names a secret by a placeholder and never holds its value: the
// value replaces the placeholder only in the request fetch sends, and every
// value sent so far is masked in whatever comes back into the script or goes
// out of it.
//
// A name resolves in the session's own group; another group the session's
// group reads is named explicitly, and its placeholder carries it as
// `wuhu-secret.<group>:<name>.<suffix>`.
final class ScriptSecrets: Sendable {
  private static let prefix = Array("wuhu-secret.".utf8)
  private static let mask = Array("***".utf8)

  private let stores: SpaceSecretStores?
  private let space: Space
  private let session: SessionID
  private let suffix: [UInt8]
  private let sent = Mutex<[[UInt8]]>([])

  init(stores: SpaceSecretStores?, space: Space, session: SessionID) {
    @Dependency(\.uuid) var uuid
    self.stores = stores
    self.space = space
    self.session = session
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

  /// The session's own group's secrets.
  func vault() async throws -> SpaceSecrets {
    try await store(in: nil)
  }

  /// Secret names of the session's group, or of `group` when named: one its
  /// group reads, never by fallback.
  func names(in group: String?) async throws -> [String] {
    if let group { try SpaceSecrets.validate(group: group) }
    return try await store(in: group).names()
  }

  func set(_ name: String, to value: String) async throws {
    let acting = try await space.principal(of: session).group
    guard try await space.isAdmin(.session(session), of: acting) else {
      throw ScriptError("setting a secret needs an admin of group \(acting.rawValue)" + (await notAdmin(session, of: acting, space: space)))
    }
    try await vault().set(name, to: value)
  }

  // Removal can't be undone, so it is a person's: `wuhu secret rm`.
  func remove(_ name: String) async throws {
    let acting = try await space.principal(of: session).group
    throw ScriptError("removing secret \(name) can't be undone and needs a human admin of group \(acting.rawValue)")
  }

  private func store(in named: String?) async throws -> SpaceSecrets {
    guard let stores else { throw ScriptError("this server has no secret store") }
    let acting = try await space.principal(of: session).group
    guard let named, named != acting.rawValue else { return try stores.group(acting.rawValue) }
    guard try await space.reads(acting).contains(GroupID(rawValue: named)) else {
      throw ScriptError("group \(acting.rawValue) does not read group \(named), so its secrets are out of reach")
    }
    return try stores.group(named)
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
        let value = Array(try await store(in: group).value(of: name).utf8)
        values[key] = value
        protect(String(decoding: value, as: UTF8.self))
      }
      output += values[key]!
      rest = bytes[end...]
    }
    return output + rest
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

/// Why `session` is no admin of `group`, worded for the caller: only a live
/// top-level agent of a group administers it.
func notAdmin(_ session: SessionID, of group: GroupID, space: Space) async -> String {
  guard let caller = try? await space.sessions.record(session) else { return "" }
  if caller.kind == .task { return "; a task never is one" }
  if caller.parent != nil { return "; a child agent never is one" }
  if caller.group != group { return "; you are a top-level agent of group \(caller.group.rawValue), not of \(group.rawValue)" }
  return ""
}
