#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import MachineContract
import struct OperationProtocol.OperationError
import SessionDomain
import struct SpaceContract.GroupID
import Synchronization

final class ExecTokens: Sendable {
  static let prefix: String = "wst_"
  static let longestLife: Double = 24 * 60 * 60

  struct Holder: Hashable, Sendable {
    var session: SessionID
    var exec: ExecID
    var expiresAt: Date
  }

  struct V2Key: Hashable, Sendable { let session: SessionID; let group: GroupID; let scope: String; let key: String }
  struct V2Holder: Sendable { let key: V2Key; let expiresAt: Date; let active: @Sendable () async throws -> Bool }
  private let v2 = Mutex<[V2Key: (token: [UInt8], holder: V2Holder, attempts: Int, issued: Bool)]>([:])
  let spaceURL: String
  let idTokens = IDTokenGrants()
  private let held = Mutex<[ExecID: (token: [UInt8], holder: Holder)]>([:])

  init(spaceURL: String) {
    self.spaceURL = spaceURL
  }

  func credential(session: SessionID, exec: ExecID, timeout: Double?, now: Date) -> ExecSessionCredential {
    let life = min(timeout.flatMap { $0 > 0 ? $0 : nil } ?? Self.longestLife, Self.longestLife)
    let token = held.withLock { held in
      held = held.filter { $0.value.holder.expiresAt > now }
      if let existing = held[exec], existing.holder.session == session {
        return String(decoding: existing.token, as: UTF8.self)
      }
      let token = Array(Self.randomToken().utf8)
      held[exec] = (token, Holder(session: session, exec: exec, expiresAt: now.addingTimeInterval(life)))
      return String(decoding: token, as: UTF8.self)
    }
    return ExecSessionCredential(token: token, spaceURL: spaceURL)
  }

  func credential(session: SessionID, group: GroupID, scope: String, key: String, timeout: Duration, now: Date, previouslyIssued: Bool = false, reserveAttempt: Bool = false, active: @escaping @Sendable () async throws -> Bool) throws -> JSONValue {
    let identity = V2Key(session: session, group: group, scope: scope, key: key)
    return try v2.withLock { held in
      held = held.filter { $0.value.holder.expiresAt.addingTimeInterval(Self.longestLife) > now }
      if held[identity] == nil {
        guard !previouslyIssued else { throw OperationError(.credentialExpired, message: "Session exec credential unavailable; credentials are not renewed") }
        guard held.count < 65536 else { throw OperationError.capacityExceeded("execCredentials", used: held.count, limit: 65536) }
        let life = min(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18, Self.longestLife)
        let expiry = now.addingTimeInterval(life)
        guard expiry > now else { throw OperationError(.invalidInput, message: "Session exec credential requires a positive lifetime") }
        held[identity] = (Array(Self.randomToken().utf8), V2Holder(key: identity, expiresAt: expiry, active: active), 0, previouslyIssued)
      }
      let entry = held[identity]!
      guard entry.holder.expiresAt > now else { throw OperationError(.credentialExpired, message: "Session exec credential expired; credentials are not renewed") }
      if reserveAttempt { held[identity]?.attempts += 1 }
      return ["token": .string(String(decoding: entry.token, as: UTF8.self)), "spaceURL": .string(spaceURL), "expiresAt": .number(entry.holder.expiresAt.timeIntervalSince1970)]
    }
  }

  func finishCredentialAttempt(session: SessionID, group: GroupID, scope: String, key: String, claimed: Bool) {
    let identity = V2Key(session: session, group: group, scope: scope, key: key)
    v2.withLock { held in
      guard var entry = held[identity] else { return }
      precondition(entry.attempts > 0)
      entry.attempts -= 1
      entry.issued = entry.issued || claimed
      if entry.attempts == 0 && !entry.issued { held.removeValue(forKey: identity) }
      else { held[identity] = entry }
    }
  }

  func v2Holder(ofBearer bearer: String) -> V2Holder? {
    let presented = Array(bearer.utf8)
    return v2.withLock { held in
      var found: V2Holder?
      for entry in held.values where execTokenEqual(entry.token, presented) { found = entry.holder }
      return found
    }
  }

  static func randomToken(prefix tokenPrefix: String = ExecTokens.prefix) -> String {
    var generator = SystemRandomNumberGenerator()
    let digits = Array("0123456789abcdef".utf8)
    var token = Array(tokenPrefix.utf8)
    for _ in 0 ..< 32 {
      let byte = UInt8.random(in: .min ... .max, using: &generator)
      token += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
    }
    return String(decoding: token, as: UTF8.self)
  }

  func revoke(_ exec: ExecID) {
    _ = held.withLock { $0.removeValue(forKey: exec) }
    idTokens.revoke(exec)
  }

  // Every held token is compared in full, so the time taken says nothing about
  // how much of a guess matched.
  func holder(ofBearer bearer: String, now: Date) -> Holder? {
    let presented = Array(bearer.utf8)
    return held.withLock { held in
      var found: Holder?
      for (token, holder) in held.values where execTokenEqual(token, presented) {
        found = holder
      }
      guard let found, found.expiresAt > now else { return nil }
      return found
    }
  }
}

/// The capability a session's exec gets in `WUHU_ID_TOKEN_REQUEST`: it mints
/// OIDC tokens for that session, machine and exec at `/v1/id-token`, and
/// nothing else. It lives in memory, so a server restart ends it too.
final class IDTokenGrants: Sendable {
  static let prefix: String = "wit_"

  struct Grant: Equatable, Sendable {
    let session: SessionID
    let machine: MachineID
    let exec: ExecID
    let expiresAt: Date
  }

  private let held = Mutex<[ExecID: (token: [UInt8], grant: Grant)]>([:])

  func environment(spaceURL: String, session: SessionID, machine: MachineID, exec: ExecID, timeout: Double?, now: Date) -> (url: String, request: String) {
    let life = min(timeout.flatMap { $0 > 0 ? $0 : nil } ?? ExecTokens.longestLife, ExecTokens.longestLife)
    let token = held.withLock { held in
      held = held.filter { $0.value.grant.expiresAt > now }
      if let existing = held[exec], existing.grant.session == session, existing.grant.machine == machine {
        return String(decoding: existing.token, as: UTF8.self)
      }
      let token = Array(ExecTokens.randomToken(prefix: Self.prefix).utf8)
      held[exec] = (token, Grant(session: session, machine: machine, exec: exec, expiresAt: now.addingTimeInterval(life)))
      return String(decoding: token, as: UTF8.self)
    }
    return (spaceURL + "/v1/id-token", token)
  }

  func grant(ofBearer bearer: String, now: Date) -> Grant? {
    let presented = Array(bearer.utf8)
    return held.withLock { held in
      var found: Grant?
      for (token, grant) in held.values where execTokenEqual(token, presented) { found = grant }
      guard let found, found.expiresAt > now else { return nil }
      return found
    }
  }

  func revoke(_ exec: ExecID) {
    _ = held.withLock { $0.removeValue(forKey: exec) }
  }

  /// When `exec`'s grant lapses, or nil when it holds none.
  func expiry(of exec: ExecID) -> Date? {
    held.withLock { $0[exec]?.grant.expiresAt }
  }
}

private func execTokenEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  var difference: UInt8 = 0
  for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
  return difference == 0
}
