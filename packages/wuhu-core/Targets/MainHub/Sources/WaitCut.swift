import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

/// What ends an exec or run_script call's wait before its work ends.
public enum WaitCut: Sendable, Equatable {
  /// The call's `wait_seconds` passed.
  case waited(Double)
  /// The call was told to yield.
  case arrival

  /// Says why the call returned `running`.
  public var reason: String {
    switch self {
    case let .waited(wait): "still running after \(seconds(.seconds(wait))) s"
    case .arrival: "a message arrived, so the call gave the turn back; still running"
    }
  }

  /// Whichever comes first: `wait` seconds, or the call told to yield. Nil once the call is cancelled.
  public static func first(wait: Double, yielded: @escaping @Sendable () async -> Bool) async -> WaitCut? {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    return await withTaskGroup(of: WaitCut?.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        do { try await clock.sleep(for: .seconds(wait)) } catch { return nil }
        return .waited(wait)
      }
      group.addTask { await yielded() ? .arrival : nil }
      while let next = await group.next() {
        if let next { return next }
        if Task.isCancelled { return nil }
      }
      return nil
    }
  }
}
