#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import enum JSONValue.JSONValue
import MachineContract
import SessionDomain
import SpaceContract
import SpaceCore
import Synchronization

final class ExecTokens: Sendable {
  static let prefix = "wst_"
  static let longestLife: Double = 24 * 60 * 60
  let spaceURL: String
  let identity: IdentityController
  var space: Space { identity.space }

  init(spaceURL: String, identity: IdentityController) {
    self.spaceURL = spaceURL
    self.identity = identity
  }

  func sessionToken(_ session: SessionID) async throws -> String {
    @Dependency(\.date) var date
    let group = try await space.principal(of: session).group
    return try await Self.prefix + identity.credential(session: session, group: group, exec: nil, now: date.now, lifetime: 300)
  }

  func credential(session: SessionID, group: GroupID, machine: MachineID, exec: ExecID, timeout: Duration, issuedAt: Date) async throws -> JSONValue {
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    precondition(seconds > 0)
    let life = Int(min(seconds.rounded(.up), Self.longestLife))
    let token = try await identity.credential(session: session, group: group, exec: ExecClaims(machine: machine.rawValue, exec: exec.rawValue), now: issuedAt, lifetime: life)
    return ["token": .string(Self.prefix + token), "spaceURL": .string(spaceURL), "expiresAt": .number(Double(Int(issuedAt.timeIntervalSince1970) + life))]
  }

  // A sessionless script's token for one run (an observer's firing, a
  // person's terminal script): minted when the run goes to a worker, revoked
  // when it comes back.
  private let scripts = Mutex<[[UInt8]: SessionlessScript]>([:])

  func scriptToken(_ script: SessionlessScript) -> String {
    let token = Self.randomToken()
    scripts.withLock { $0[Array(token.utf8)] = script }
    return token
  }

  func revokeScript(_ token: String) {
    _ = scripts.withLock { $0.removeValue(forKey: Array(token.utf8)) }
  }

  nonisolated(nonsending) func runSessionless<T>(_ sessionless: SessionlessScript, _ body: (String) async throws -> T) async throws -> T {
    let token = scriptToken(sessionless)
    defer { revokeScript(token) }
    return try await withTaskCancellationHandler {
      try await body(token)
    } onCancel: {
      revokeScript(token)
    }
  }

  func script(ofBearer bearer: String) -> SessionlessScript? {
    let presented = Array(bearer.utf8)
    return scripts.withLock { held in
      var found: SessionlessScript?
      for (token, script) in held where execTokenEqual(token, presented) { found = script }
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
}

private func execTokenEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  var difference: UInt8 = 0
  for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
  return difference == 0
}
