#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import SessionDomain
import Synchronization

// The credential of one session's exec: 32 random bytes, handed to the machine
// inside that exec's start and held only here, so a server restart forgets
// them all. The hub mints one when it relays the start; a replayed start gets
// the same one back. It is good until the exec ends or its timeout passes,
// capped at a day; the gate checks the exec's end against the registry.
package final class ExecTokens: Sendable {
  package static let prefix: String = "wst_"
  package static let longestLife: Double = 24 * 60 * 60

  package struct Holder: Hashable, Sendable {
    package var session: SessionID
    package var exec: ExecID
    package var expiresAt: Date
  }

  package let spaceURL: String
  private let held = Mutex<[ExecID: (token: [UInt8], holder: Holder)]>([:])

  package init(spaceURL: String) {
    self.spaceURL = spaceURL
  }

  package func credential(session: SessionID, exec: ExecID, timeout: Double?, now: Date) -> ExecSessionCredential {
    let life = min(timeout.flatMap { $0 > 0 ? $0 : nil } ?? Self.longestLife, Self.longestLife)
    let token = held.withLock { held in
      held = held.filter { $0.value.holder.expiresAt > now }
      if let existing = held[exec], existing.holder.session == session {
        return String(decoding: existing.token, as: UTF8.self)
      }
      var generator = SystemRandomNumberGenerator()
      let digits = Array("0123456789abcdef".utf8)
      var token = Array(Self.prefix.utf8)
      for _ in 0 ..< 32 {
        let byte = UInt8.random(in: .min ... .max, using: &generator)
        token += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
      }
      held[exec] = (token, Holder(session: session, exec: exec, expiresAt: now.addingTimeInterval(life)))
      return String(decoding: token, as: UTF8.self)
    }
    return ExecSessionCredential(token: token, spaceURL: spaceURL)
  }

  package func revoke(_ exec: ExecID) {
    _ = held.withLock { $0.removeValue(forKey: exec) }
  }

  // Every held token is compared in full, so the time taken says nothing about
  // how much of a guess matched.
  package func holder(ofBearer bearer: String, now: Date) -> Holder? {
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

private func execTokenEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  var difference: UInt8 = 0
  for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
  return difference == 0
}
