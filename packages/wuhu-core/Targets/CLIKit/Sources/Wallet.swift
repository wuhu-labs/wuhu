#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

import JSONValue
import struct SpaceClient.ObserveRequest

struct Wallet {
  var directory: URL
  /// The acting group, when one is selected: it scopes the read-before-write
  /// tokens and observe cursors, whose keys are unchanged without one. The
  /// inbox cursor is the space's alone: a person has one inbox across groups.
  var group: String?
  private let pinTarget: URL
  private var config: Config?
  private var configIsMalformed: Bool
  private var etags: [String: String]?
  private var warnings: [String]

  static func locate(currentDirectory: String, environment: [String: String]) throws -> Self {
    let manager = FileManager.default
    let cwd = URL(fileURLWithPath: currentDirectory, isDirectory: true).standardizedFileURL
    let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
      ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let homeWallet = home.appendingPathComponent(".wuhu", isDirectory: true).standardizedFileURL
    let localWallet = cwd.appendingPathComponent(".wuhu", isDirectory: true)
    var candidate = cwd
    while true {
      let wallet = candidate.appendingPathComponent(".wuhu", isDirectory: true)
      if wallet.standardizedFileURL.path != homeWallet.path, manager.fileExists(atPath: wallet.path) {
        let values = try wallet.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          throw UsageError(message: "found .wuhu but it is not a directory")
        }
        return Self(directory: wallet, pinTarget: wallet)
      }
      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path { break }
      candidate = parent
    }

    return Self(directory: localWallet, pinTarget: localWallet)
  }

  init(directory: URL, pinTarget: URL? = nil) {
    self.directory = directory
    self.pinTarget = pinTarget ?? directory
    do {
      self.config = try Self.read(Config.self, at: directory.appendingPathComponent("config.json"))
      self.configIsMalformed = false
    } catch {
      self.config = nil
      self.configIsMalformed = true
    }
    self.etags = nil
    self.warnings = []
  }

  // A session's exec: pinned to the space its token acts on, reading no
  // config from disk; only the scratch state (etags, cursors) is kept there.
  init(sessionState directory: URL, space: String) {
    self.directory = directory
    self.pinTarget = directory
    self.config = Config(space: space)
    self.configIsMalformed = false
    self.etags = nil
    self.warnings = []
  }

  mutating func pin(_ space: String, group: String?) throws -> URL {
    let config = Config(space: space, group: group)
    try FileManager.default.createDirectory(at: self.pinTarget, withIntermediateDirectories: true)
    try Self.write(config, at: self.pinTarget.appendingPathComponent("config.json"))
    self.directory = self.pinTarget
    self.config = config
    self.configIsMalformed = false
    return self.pinTarget
  }

  var configuredGroup: String? {
    self.config?.group
  }

  mutating func setGroup(_ group: String?) throws -> URL {
    let config = Config(space: try self.pinnedSpace(), group: group)
    let url = self.directory.appendingPathComponent("config.json")
    try Self.write(config, at: url)
    self.config = config
    return url
  }

  func pinnedSpace() throws -> String {
    if self.configIsMalformed {
      throw UsageError(message: "malformed .wuhu/config.json; run: wuhu use <host:port> to repair")
    }
    guard let space = self.config?.space else {
      throw UsageError(message: "no space pinned; run: wuhu use <host:port>")
    }
    return space
  }

  mutating func token(space: String, path: String) throws -> String? {
    try self.loadEtags()[self.etagKey(space: space, path: path)]
  }

  mutating func record(token: String, space: String, path: String) throws {
    var etags = try self.loadEtags()
    etags[self.etagKey(space: space, path: path)] = token
    try self.storeEtags(etags)
  }

  mutating func removeToken(space: String, path: String) throws {
    var etags = try self.loadEtags()
    etags.removeValue(forKey: self.etagKey(space: space, path: path))
    try self.storeEtags(etags)
  }

  mutating func moveTokens(space: String, from: String, to: String) throws {
    var etags = try self.loadEtags()
    let fromKey = self.etagKey(space: space, path: from)
    let fromPrefix = self.etagKey(space: space, path: from.hasSuffix("/") ? from : from + "/")
    var updates: [(String, String)] = []
    for (key, token) in etags {
      if key == fromKey {
        updates.append((self.etagKey(space: space, path: to), token))
        etags.removeValue(forKey: key)
      } else if key.hasPrefix(fromPrefix) {
        let suffix = key.dropFirst(fromPrefix.count)
        let movedPath = (to.hasSuffix("/") ? to : to + "/") + suffix
        updates.append((self.etagKey(space: space, path: movedPath), token))
        etags.removeValue(forKey: key)
      }
    }
    for (key, token) in updates {
      etags[key] = token
    }
    try self.storeEtags(etags)
  }

  func observationState(space: String, mode: ObserveRequest.Mode) -> URL {
    let key: String
    switch mode {
    case let .glob(pattern):
      key = "\(self.scope(space))|glob:\(pattern)"
    case let .sql(query):
      key = "\(self.scope(space))|sql:\(query)"
    }
    return self.directory
      .appendingPathComponent("observations", isDirectory: true)
      .appendingPathComponent(SHA256.hex(key) + ".json")
  }

  mutating func readObservationHash(space: String, mode: ObserveRequest.Mode) -> String? {
    let url = self.observationState(space: space, mode: mode)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let value = JSONValue.parse(text),
          let hash = value.object?["hash"]?.stringValue
    else {
      self.warnings.append("warning: ignoring malformed \(url.path)\n")
      return nil
    }
    return hash
  }

  func writeObservationHash(_ hash: String, space: String, mode: ObserveRequest.Mode) throws {
    let url = self.observationState(space: space, mode: mode)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{\"hash\":\"\(hash)\"}\n".write(to: url, atomically: true, encoding: .utf8)
  }

  // One server-minted persona per wallet x space, reused forever after: a
  // lost/reset file would change who we claim to be, so a malformed file
  // fails loudly instead of silently re-minting.
  mutating func persona(space: String) throws -> String? {
    let url = self.personasFile
    do {
      return try Self.read([String: String].self, at: url)?[space]
    } catch {
      throw UsageError(message: "malformed \(url.path); fix or remove it")
    }
  }

  mutating func recordPersona(_ persona: String, space: String) throws {
    var personas = (try? Self.read([String: String].self, at: self.personasFile)) ?? [:]
    personas[space] = persona
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    try Self.write(personas, at: self.personasFile)
  }

  private var personasFile: URL {
    self.directory.appendingPathComponent("personas.json")
  }

  // Live bearer credentials: owner-only like device keys, but re-mintable, so
  // a loose file is dropped and rewritten tight instead of a hard error.
  mutating func assertion(space: String) -> String? {
    let url = self.directory.appendingPathComponent("assertions.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard Self.isOwnerOnly(url) else {
      self.warnings.append("""
      warning: \(url.path) was not owner-only; the cached assertion may already have been read \
      and stays valid until it expires — discarding it here does not revoke it. to revoke now, \
      remove this device's key from the space (offline: wuhu user reset), then re-enroll: wuhu login\n
      """)
      return nil
    }
    do {
      return try Self.read([String: String].self, at: url)?[space]
    } catch {
      self.warnings.append("warning: ignoring malformed \(url.path)\n")
      return nil
    }
  }

  // Best-effort: the assertion is already minted and in memory, so the cache is
  // pure convenience for the next verb. A write we cannot do safely — a symlink
  // we refuse to follow, a read-only wallet, a full disk — warns and is skipped,
  // never failing the command; the next verb simply re-mints.
  mutating func recordAssertion(_ raw: String, space: String) {
    let url = self.directory.appendingPathComponent("assertions.json")
    do {
      // A loose file is untrusted: never merge its entries into the tightened cache.
      var assertions = Self.isOwnerOnly(url) ? ((try? Self.read([String: String].self, at: url)) ?? [:]) : [:]
      assertions[space] = raw
      try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
      try Self.writeOwnerOnly(try JSONEncoder().encode(assertions), to: url)
    } catch let error as CacheWriteError where error.isSymlink {
      self.warnings.append("""
      warning: \(url.path) is a symlink; refusing to write the assertion cache through it. \
      the command succeeded — the next command will re-mint. remove the symlink to restore caching.\n
      """)
    } catch {
      self.warnings.append("""
      warning: could not cache the assertion at \(url.path); \
      the command succeeded and the next command will re-mint.\n
      """)
    }
  }

  private struct CacheWriteError: Error {
    var isSymlink: Bool
  }

  // The secret must never exist on disk wider than 0600, and FileManager's
  // createFile stages Linux writes through a umask-mode temp file before its
  // trailing chmod — so this writes with POSIX directly: O_CREAT births a
  // same-directory temp file 0600, fsync makes it durable, and rename
  // publishes it whole. Atomicity is load-bearing, not a nicety: concurrent
  // CLI verbs rewrite the assertion cache while others read it, and a torn
  // read must never pass for a credential.
  private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
      throw CacheWriteError(isSymlink: true)
    }
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CacheWriteError(isSymlink: false) }
    do {
      guard fchmod(fd, 0o600) == 0 else { throw CacheWriteError(isSymlink: false) }
      var remaining = data
      while !remaining.isEmpty {
        #if canImport(Glibc)
          let written = remaining.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
        #else
          let written = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        #endif
        if written < 0 {
          if errno == EINTR { continue }
          throw CacheWriteError(isSymlink: false)
        }
        remaining = remaining.dropFirst(written)
      }
      guard fsync(fd) == 0 else { throw CacheWriteError(isSymlink: false) }
      close(fd)
    } catch {
      close(fd)
      unlink(temp.path)
      throw error
    }
    guard rename(temp.path, url.path) == 0 else {
      unlink(temp.path)
      throw CacheWriteError(isSymlink: false)
    }
  }

  private static func isOwnerOnly(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let mode = posixMode(attributes[.posixPermissions])
    else { return false }
    return mode & 0o077 == 0
  }

  // One read position per space, whatever the acting group. A cursor an
  // older CLI kept per group ("space|group") still counts: the furthest one
  // read wins, so nothing already printed comes back.
  mutating func inboxCursor(space: String) -> Int {
    let url = self.directory.appendingPathComponent("inbox.json")
    do {
      let cursors = try Self.read([String: Int].self, at: url) ?? [:]
      return cursors.filter { $0.key == space || $0.key.hasPrefix("\(space)|") }.values.max() ?? 0
    } catch {
      self.warnings.append("warning: ignoring malformed \(url.path)\n")
      return 0
    }
  }

  mutating func advanceInboxCursor(_ n: Int, space: String) throws {
    let url = self.directory.appendingPathComponent("inbox.json")
    var cursors = (try? Self.read([String: Int].self, at: url)) ?? [:]
    cursors = cursors.filter { !$0.key.hasPrefix("\(space)|") }
    cursors[space] = n
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    try Self.write(cursors, at: url)
  }

  mutating func drainWarnings() -> [String] {
    defer { self.warnings = [] }
    return self.warnings
  }

  private mutating func loadEtags() throws -> [String: String] {
    if let etags { return etags }
    let url = self.directory.appendingPathComponent("etags.json")
    do {
      let loaded = try Self.read([String: String].self, at: url) ?? [:]
      self.etags = loaded
      return loaded
    } catch {
      self.warnings.append("warning: ignoring malformed \(url.path)\n")
      self.etags = [:]
      return [:]
    }
  }

  private mutating func storeEtags(_ etags: [String: String]) throws {
    self.etags = etags
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    try Self.write(etags, at: self.directory.appendingPathComponent("etags.json"))
  }

  private func etagKey(space: String, path: String) -> String {
    "\(self.scope(space))|\(path)"
  }

  private func scope(_ space: String) -> String {
    self.group.map { "\(space)|\($0)" } ?? space
  }

  private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(type, from: data)
  }

  private static func write(_ value: some Encodable, at url: URL) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: url, options: .atomic)
  }
}

private struct Config: Codable {
  var space: String
  var group: String?
}
