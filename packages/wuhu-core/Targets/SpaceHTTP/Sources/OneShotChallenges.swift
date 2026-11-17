#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Synchronization

// One-shot challenges: minted unauthenticated, burned at first take, dead
// after the lifetime — a captured handshake can never replay.
public final class OneShotChallenges: Sendable {
  private let expiries = Mutex<[String: Date]>([:])
  private let dateGen: DateGenerator
  private let rng: WithRandomNumberGenerator
  private let prefix: String
  private let lifetime: TimeInterval

  public init(prefix: String, lifetime: TimeInterval = 60) {
    @Dependency(\.date) var date
    @Dependency(\.withRandomNumberGenerator) var rng
    dateGen = date
    self.rng = rng
    self.prefix = prefix
    self.lifetime = lifetime
  }

  public func mint() -> String {
    let now = dateGen.now
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    let challenge = rng { generator in
      prefix + String((0 ..< 32).map { _ in alphabet.randomElement(using: &generator)! })
    }
    expiries.withLock { state in
      state = state.filter { now < $0.value }
      // The mint route is unauthenticated; the cap bounds memory under a
      // flood, at worst forcing a concurrent legit dial to redial.
      while state.count >= 4096 {
        state.removeValue(forKey: state.keys.first!)
      }
      state[challenge] = now.addingTimeInterval(lifetime)
    }
    return challenge
  }

  public func take(_ challenge: String) -> Bool {
    let now = dateGen.now
    return expiries.withLock { state in
      guard let expiry = state.removeValue(forKey: challenge) else { return false }
      return now < expiry
    }
  }
}
