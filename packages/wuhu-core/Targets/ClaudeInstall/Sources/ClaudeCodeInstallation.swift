#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Synchronization

/// One install at a time: callers that arrive while one runs wait for it and share its outcome, and a caller after it ended starts a new one. A cancelled caller stops waiting at once; the install goes on for the others.
public final class ClaudeCodeInstallation: Sendable {
  private struct State {
    var installing = false
    var nextWaiter = 0
    var waiters: [Int: CheckedContinuation<URL, any Error>] = [:]
  }

  public let installer: ClaudeInstaller
  private let state = Mutex(State())

  public init(_ installer: ClaudeInstaller) {
    self.installer = installer
  }

  public func ready() async throws -> URL {
    let waiter = state.withLock { state in
      defer { state.nextWaiter += 1 }
      return state.nextWaiter
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let start = state.withLock { state -> Bool in
          // Checked under the lock onCancel takes, so a cancellation is seen either here or there.
          guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return false
          }
          state.waiters[waiter] = continuation
          guard !state.installing else { return false }
          state.installing = true
          return true
        }
        if start {
          let installer = installer
          Task {
            let result: Result<URL, any Error>
            do {
              result = try .success(await installer.install())
            } catch {
              result = .failure(error)
            }
            self.finish(result)
          }
        }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: waiter) }?.resume(throwing: CancellationError())
    }
  }

  private func finish(_ result: Result<URL, any Error>) {
    let waiters = state.withLock { state in
      state.installing = false
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    for waiter in waiters {
      waiter.resume(with: result)
    }
  }
}
