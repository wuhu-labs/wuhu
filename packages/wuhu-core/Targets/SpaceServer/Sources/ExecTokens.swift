#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import MachineContract
import struct MainHub.WorkerID
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
  // The worker's token for a mounted session: minted once, good until the
  // session is archived.
  private let sessions = Mutex<[SessionID: [UInt8]]>([:])

  init(spaceURL: String) {
    self.spaceURL = spaceURL
  }

  func sessionToken(_ session: SessionID) -> String {
    sessions.withLock { held in
      if let token = held[session] { return String(decoding: token, as: UTF8.self) }
      let token = Array(Self.randomToken().utf8)
      held[session] = token
      return String(decoding: token, as: UTF8.self)
    }
  }

  func revokeSession(_ session: SessionID) {
    _ = sessions.withLock { $0.removeValue(forKey: session) }
  }

  // A worker's own token, minted once per worker by the registry: the routes
  // that serve the loop's journal and queue take these and nothing else, and
  // a drained worker's ends with it.
  private let workers = Mutex<[WorkerID: [UInt8]]>([:])

  func workerToken(_ worker: WorkerID) -> String {
    workers.withLock { held in
      if let token = held[worker] { return String(decoding: token, as: UTF8.self) }
      let token = Array(Self.randomToken().utf8)
      held[worker] = token
      return String(decoding: token, as: UTF8.self)
    }
  }

  func hasWorker(_ worker: WorkerID) -> Bool { workers.withLock { $0[worker] != nil } }

  func revokeWorker(_ worker: WorkerID) {
    _ = workers.withLock { $0.removeValue(forKey: worker) }
  }

  func worker(ofBearer bearer: String) -> WorkerID? {
    let presented = Array(bearer.utf8)
    return workers.withLock { held in
      var found: WorkerID?
      for (worker, token) in held where execTokenEqual(token, presented) { found = worker }
      return found
    }
  }

  func session(ofBearer bearer: String) -> SessionID? {
    let presented = Array(bearer.utf8)
    return sessions.withLock { held in
      var found: SessionID?
      for (session, token) in held where execTokenEqual(token, presented) { found = session }
      return found
    }
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

  /// Every token held here, as the main taking over from this one restores
  /// them: a mounted session's, a worker's, a running exec's, and the OIDC
  /// grants and machine v2 credentials issued to execs. A v2 credential not
  /// yet issued is left out; its caller asks again.
  struct Table: Codable, Sendable {
    struct Exec: Codable, Sendable { var exec: String; var session: String; var token: String; var expiresAt: Double }
    struct Grant: Codable, Sendable { var exec: String; var session: String; var machine: String; var token: String; var expiresAt: Double }
    struct V2: Codable, Sendable { var session: String; var group: String; var scope: String; var key: String; var token: String; var expiresAt: Double }
    var sessions: [String: String] = [:]
    var workers: [String: String] = [:]
    var execs: [Exec] = []
    var grants: [Grant] = []
    var v2: [V2] = []
  }

  func table() -> Table {
    func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
    var table = Table()
    table.sessions = Dictionary(uniqueKeysWithValues: sessions.withLock { $0.map { ($0.key.rawValue, text($0.value)) } })
    table.workers = Dictionary(uniqueKeysWithValues: workers.withLock { $0.map { ($0.key.rawValue, text($0.value)) } })
    table.execs = held.withLock { held in
      held.values.map { Table.Exec(exec: $0.holder.exec.rawValue, session: $0.holder.session.rawValue, token: text($0.token), expiresAt: $0.holder.expiresAt.timeIntervalSince1970) }
    }
    table.grants = idTokens.table()
    table.v2 = v2.withLock { held in
      held.values.filter(\.issued).map { entry in
        let key = entry.holder.key
        return Table.V2(session: key.session.rawValue, group: key.group.rawValue, scope: key.scope, key: key.key, token: text(entry.token), expiresAt: entry.holder.expiresAt.timeIntervalSince1970)
      }
    }
    return table
  }

  /// Takes over `table`'s tokens; `active` says, for a v2 credential, whether
  /// its exec still runs.
  func restore(_ table: Table, active: (V2Key) -> @Sendable () async throws -> Bool) {
    sessions.withLock { held in
      for (session, token) in table.sessions { held[SessionID(session)] = Array(token.utf8) }
    }
    workers.withLock { held in
      for (worker, token) in table.workers { held[WorkerID(worker)] = Array(token.utf8) }
    }
    held.withLock { held in
      for exec in table.execs {
        let holder = Holder(session: SessionID(exec.session), exec: ExecID(rawValue: exec.exec), expiresAt: Date(timeIntervalSince1970: exec.expiresAt))
        held[holder.exec] = (Array(exec.token.utf8), holder)
      }
    }
    idTokens.restore(table.grants)
    v2.withLock { held in
      for credential in table.v2 {
        let key = V2Key(session: SessionID(credential.session), group: GroupID(rawValue: credential.group), scope: credential.scope, key: credential.key)
        held[key] = (Array(credential.token.utf8), V2Holder(key: key, expiresAt: Date(timeIntervalSince1970: credential.expiresAt), active: active(key)), 0, true)
      }
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

  func table() -> [ExecTokens.Table.Grant] {
    held.withLock { held in
      held.values.map { token, grant in
        ExecTokens.Table.Grant(
          exec: grant.exec.rawValue, session: grant.session.rawValue, machine: grant.machine.rawValue,
          token: String(decoding: token, as: UTF8.self), expiresAt: grant.expiresAt.timeIntervalSince1970,
        )
      }
    }
  }

  func restore(_ grants: [ExecTokens.Table.Grant]) {
    held.withLock { held in
      for grant in grants {
        let restored = Grant(
          session: SessionID(grant.session), machine: MachineID(rawValue: grant.machine), exec: ExecID(rawValue: grant.exec),
          expiresAt: Date(timeIntervalSince1970: grant.expiresAt),
        )
        held[restored.exec] = (Array(grant.token.utf8), restored)
      }
    }
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
