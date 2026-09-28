#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Fetch.FetchClient
import struct NIOCore.TimeAmount
import enum PinnedTLS.PinnedTLS
import enum PinnedTLS.SystemTrust
import enum PinnedTLS.TrustAnchors
import enum PinnedTLS.TrustPolicy

public struct ServerTrust: Sendable {
  public var directory: URL

  public init(environment: [String: String]) throws {
    self.directory = try Self.userConfigDirectory(environment: environment)
  }

  public init(directory: URL) {
    self.directory = directory
  }

  // An empty path would resolve CWD-relative and silently recreate a
  // per-folder store; reject it as loudly as an unset HOME.
  public static func userConfigDirectory(environment: [String: String]) throws -> URL {
    if let override = environment["WUHU_CONFIG_DIR"] {
      guard !override.isEmpty else {
        throw CLIError(message: "WUHU_CONFIG_DIR is set but empty")
      }
      return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    guard let home = environment["HOME"], !home.isEmpty else {
      throw CLIError(message: "HOME is not set; cannot locate ~/.wuhu")
    }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".wuhu", isDirectory: true).standardizedFileURL
  }

  public static func hostKey(url: URL) -> String? {
    guard let host = url.host else { return nil }
    return "\(host):\(url.port ?? 443)"
  }

  public func pin(forHost key: String) throws -> String? {
    try self.load()[key]
  }

  public static func isFingerprint(_ value: String) -> Bool {
    value.count == 71 && value.hasPrefix("sha256:")
      && value.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
  }

  public func record(_ fingerprint: String, forHost key: String) throws {
    precondition(Self.isFingerprint(fingerprint), "trust records are sha256:<64 lowercase hex> fingerprints, got \(fingerprint)")
    var pins = try self.load()
    pins[key] = fingerprint
    try self.save(pins)
  }

  public func removePin(forHost key: String) throws {
    var pins = try self.load()
    guard pins.removeValue(forKey: key) != nil else { return }
    try self.save(pins)
  }

  private var file: URL {
    self.directory.appendingPathComponent("trust.json")
  }

  private func load() throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: self.file.path) else { return [:] }
    let data = try Data(contentsOf: self.file)
    guard let pins = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw MalformedTrustStore(file: self.file, reason: "not a JSON object of host to fingerprint")
    }
    if let (host, value) = pins.first(where: { !Self.isFingerprint($0.value) }) {
      throw MalformedTrustStore(
        file: self.file,
        reason: "value for \(host) is not a sha256:<64 lowercase hex> fingerprint (got \(value.prefix(24))…)",
      )
    }
    return pins
  }

  private func save(_ pins: [String: String]) throws {
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try (try encoder.encode(pins)).write(to: self.file, options: .atomic)
  }
}

public struct MalformedTrustStore: Error, CustomStringConvertible, Sendable {
  public let file: URL
  public let reason: String

  public var description: String {
    """
    malformed trust store \(self.file.path): \(self.reason)
    fix or remove it, then re-establish trust: wuhu use <host:port> [--pin]
    """
  }
}

public struct UntrustedServer: Error, CustomStringConvertible, Sendable {
  public let host: String
  public let cause: String

  public var description: String {
    """
    \(self.host) presented a certificate this system does not trust: \(self.cause)
    to pin its certificate instead (trust on first use), run:
      wuhu use \(self.host) --pin
    """
  }
}

public struct PinMismatch: Error, CustomStringConvertible, Sendable {
  public let host: String
  public let pinnedFingerprint: String
  public let observedFingerprint: String

  public var description: String {
    """
    server certificate changed for \(self.host)
      pinned:   \(self.pinnedFingerprint)
      observed: \(self.observedFingerprint)
    if you expected this change (server reinstalled, tunnel target moved), re-trust with:
      wuhu trust \(self.host)
    if this host is a machine join target, do not re-trust blind — re-join with the exact
    fingerprint printed by wuhu machine add/rotate:
      wuhu machine join <server-url> <fingerprint> < token
    """
  }
}

public enum SpaceTransport {
  public static func isSecure(url: URL) -> Bool {
    url.scheme == "https" || url.scheme == "wss"
  }

  public static func recordedPin(url: URL, trust: ServerTrust) throws -> String? {
    guard self.isSecure(url: url), let key = ServerTrust.hostKey(url: url) else {
      return nil
    }
    return try trust.pin(forHost: key)
  }

  // Pin XOR system trust: a recorded pin puts the host in pin mode, otherwise
  // normal PKI verification applies and nothing is ever recorded implicitly.
  public static func policy(url: URL, trust: ServerTrust) throws -> TrustPolicy? {
    guard self.isSecure(url: url) else { return nil }
    guard let pin = try self.recordedPin(url: url, trust: trust) else { return .system }
    return .pinned(fingerprint: pin)
  }

  public static func fetchClient(trust: ServerTrust, timeout: TimeAmount?, plain: FetchClient) -> FetchClient {
    FetchClient { request in
      guard case let .pinned(fingerprint) = try self.policy(url: request.url, trust: trust) else {
        return try await plain(request)
      }
      return try await PinnedTLS.fetch(request, pinnedFingerprint: fingerprint, timeout: timeout)
    }
  }

  public static func diagnosing(_ client: FetchClient, trust: ServerTrust) -> FetchClient {
    FetchClient { request in
      do {
        return try await client(request)
      } catch {
        throw await self.diagnosed(error, url: request.url, trust: trust)
      }
    }
  }

  // A failure becomes a trust diagnosis only when a live TLS leaf is
  // observable; cancellation, server-down, and store errors pass through.
  public static func diagnosed(_ error: any Error, url: URL, trust: ServerTrust) async -> any Error {
    guard !(error is CancellationError), !Task.isCancelled,
          self.isSecure(url: url),
          let key = ServerTrust.hostKey(url: url),
          let host = url.host
    else {
      return error
    }
    let pinned: String?
    do {
      pinned = try trust.pin(forHost: key)
    } catch let storeError {
      return storeError
    }
    let port = url.port ?? 443
    guard let observed = try? await PinnedTLS.probeCertificate(host: host, port: port),
          let observedFingerprint = try? PinnedTLS.fingerprint(certificateDERBase64: observed)
    else {
      return error
    }
    guard let pinned else {
      do {
        try await SystemTrust.validate(host: host, port: port, anchors: .platformDefault)
        return error
      } catch let cause {
        return UntrustedServer(host: key, cause: String(describing: cause))
      }
    }
    guard observedFingerprint != pinned else { return error }
    return PinMismatch(
      host: key,
      pinnedFingerprint: pinned,
      observedFingerprint: observedFingerprint,
    )
  }
}
