#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Crypto
import Dependencies
import JSONValue
import QRCode
import struct SpaceContract.EnrollConsumeOutput
import enum SpaceContract.EnrollLink
import struct SpaceContract.ServerInfo
import enum SpaceContract.ShareLogin
import struct SpaceContract.ShareLoginChallengeOutput
import struct SpaceContract.ShareLoginOutput

struct EnrollmentEnvelope: Equatable {
  var server: String
  var token: String
  var space: String
  var fingerprint: String?

  var url: String {
    EnrollLink.format(origin: self.server, token: self.token, space: self.space, fingerprint: self.fingerprint)
  }

  static func parse(_ raw: String) -> EnrollmentEnvelope? {
    let raw = raw.strippingOneTrailingLineEnding()
    guard let url = URL(string: raw), url.scheme == "https", let host = url.host else { return nil }
    var token: String?
    var space: String?
    var fingerprint: String?
    for pair in (url.fragment ?? "").split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      switch parts[0] {
      case "token": token = String(parts[1])
      case "space": space = String(parts[1])
      case "fp": fingerprint = String(parts[1])
      default: continue
      }
    }
    guard let token, let space, isValidSpaceIdentity(space) else { return nil }
    return EnrollmentEnvelope(
      server: "https://" + host + (url.port.map { ":\($0)" } ?? ""),
      token: token,
      space: space,
      fingerprint: fingerprint,
    )
  }
}

extension Executor {
  func login() async throws {
    if self.runner.stdinIsTerminal {
      await self.runner.stderr("invite link (stdin, end with ctrl-d): ")
    }
    let raw = try await self.runner.stdin()
    guard let envelope = EnrollmentEnvelope.parse(raw) else {
      throw UsageError(message: """
      login: expected an https invite link on stdin like https://host:port/_/enroll#token=jt_...&space=spc_...&fp=sha256:...
      """)
    }
    try await self.establishDeliveredTrust(
      server: envelope.server,
      fingerprint: envelope.fingerprint,
      verb: "login",
      refingerprintHint: "ask for a fresh invite link that includes the certificate fingerprint (fp=sha256:...)",
    )
    let keys = try DeviceKeyStore(environment: self.runner.environment)
    let key = try keys.loadOrCreate(space: envelope.space)
    let body: JSONValue = .object(["token": .string(envelope.token), "pubkey": .string(key.pubkeyLabel)])
    // consume authenticates by the token itself; it must never carry an assertion.
    let output: EnrollConsumeOutput = try await self.client(envelope.server).api(.post, "/v1/enroll/consume", body: body)
    let endpoint = try self.endpoint(space: envelope.server)
    try SpaceIdentityStore(environment: self.runner.environment).record(envelope.space, forHost: endpoint.key)
    await self.runner.stdout("enrolled \(output.account) (\(output.capabilities.joined(separator: " ")))\n")
    await self.runner.stderr("""
    device key \(keys.keyFile(space: envelope.space).path)
    the invite link is now dead; next, pin this space: wuhu use \(self.endpointKey(envelope.server))

    """)
  }

  mutating func shareLogin(ttl: Int?) async throws {
    let space = try self.wallet.pinnedSpace()
    let endpoint = try self.endpoint(space: space)
    guard endpoint.secure else {
      throw UsageError(message: "share-login: the pinned space must be https")
    }
    let identities = try SpaceIdentityStore(environment: self.runner.environment)
    guard let identity = try identities.identity(forHost: endpoint.key) else {
      throw CLIError(message: """
      this device holds no key for \(endpoint.key); enroll it first: wuhu login < invite-link
      """)
    }
    let keys = try DeviceKeyStore(environment: self.runner.environment)
    guard let key = try keys.load(space: identity) else {
      throw CLIError(message: """
      this device holds no key for \(endpoint.key); enroll it first: wuhu login < invite-link
      """)
    }
    let challenged: ShareLoginChallengeOutput = try await self.api(.get, "/v1/enroll/share-login/challenge", space: space)
    let signature = try key.signature(for: Data(ShareLogin.signingMessage(challenge: challenged.challenge).utf8))
    var body: JSONValue = .object([
      "pubkey": .string(key.pubkeyLabel),
      "challenge": .string(challenged.challenge),
      "signature": .string(signature.base64EncodedString()),
    ])
    body.set("ttlSeconds", ttl.map(JSONValue.integer))
    let server = await self.advertisedServer(space: space)
    let output: ShareLoginOutput = try await self.api(.post, "/v1/enroll/share-login", space: space, body: body)
    let envelope = EnrollmentEnvelope(
      server: server,
      token: output.token,
      space: output.space,
      fingerprint: output.fingerprint,
    )
    guard let qr = QRCode.encode(envelope.url) else {
      throw CLIError(message: "share-login: the invite link does not fit a QR code: \(envelope.url)")
    }
    await self.runner.stdout(qr.terminalRendering + envelope.url + "\n")
    await self.runner.stderr("one-time link; it dies at first use or in \(lifetimePhrase(seconds: ttl ?? ShareLogin.defaultTTLSeconds))\n")
  }

  mutating func advertisedServer(space: String) async -> String {
    // Best-effort like adoptAdvertisedIdentity: a pre-discovery server walls
    // /v1/server (401) — minting must still work against the wallet pin.
    let info: ServerInfo? = try? await self.api(.get, "/v1/server", space: space)
    return info?.origin ?? self.client(space).base
  }

  func establishDeliveredTrust(server: String, fingerprint: String?, verb: String, refingerprintHint: String) async throws {
    let endpoint = try self.endpoint(space: server)
    guard let fingerprint else {
      guard endpoint.secure, try self.trust.pin(forHost: endpoint.key) == nil else { return }
      @Dependency(ServerTrustProbe.self) var probe
      do {
        try await probe.validateSystem(endpoint.host, endpoint.port)
      } catch {
        throw CLIError(message: """
        \(endpoint.key) presented a certificate this system does not trust: \(error)
        \(refingerprintHint)
        """)
      }
      return
    }
    guard endpoint.secure else {
      throw UsageError(message: "\(verb): a fingerprint requires an https server")
    }
    guard ServerTrust.isFingerprint(fingerprint) else {
      throw UsageError(message: "\(verb): fingerprint must be sha256:<64 lowercase hex>, got \(fingerprint)")
    }
    try self.trust.record(fingerprint, forHost: endpoint.key)
  }

  private func endpointKey(_ server: String) -> String {
    (try? self.endpoint(space: server).key) ?? server
  }
}

func lifetimePhrase(seconds: Int) -> String {
  func counted(_ count: Int, _ unit: String) -> String {
    "\(count) \(unit)\(count == 1 ? "" : "s")"
  }
  if seconds < 3600 { return counted((seconds + 59) / 60, "minute") }
  if seconds < 86400 { return counted(seconds / 3600, "hour") }
  return counted(seconds / 86400, "day")
}
