import Synchronization
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The earliest time a job was told to give the turn back by: its session cell mails `yield(by:)` whenever input waits, and the job keeps the earliest.
final class YieldDeadline: Sendable {
  func passed(_ client: LoopClient) async -> Bool {
    await passed(now: client.now, sleep: client.sleep)
  }

  private struct State {
    var by: Date?
    var offers: UInt64 = 0
    var changed: [UInt64: CheckedContinuation<Void, Never>] = [:]
    var waiters: UInt64 = 0
  }

  private let state: Mutex<State>

  init(_ by: Date?) {
    state = Mutex(State(by: by))
  }

  var by: Date? {
    state.withLock { $0.by }
  }

  func offer(_ by: Date) {
    let woken = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      guard state.by.map({ by < $0 }) ?? true else { return [] }
      state.by = by
      state.offers += 1
      defer { state.changed = [:] }
      return Array(state.changed.values)
    }
    for continuation in woken {
      continuation.resume()
    }
  }

  /// Runs `body` while taking every `yield(by:)` from the job's other mail, which `race` hands it.
  func collecting<Message: Sendable, Value: Sendable>(
    _ messages: AsyncStream<Message>, _ yield: @escaping @Sendable (Message) -> Date?, _ body: @escaping @Sendable () async throws -> Value,
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value?.self) { group in
      group.addTask {
        for await message in messages {
          if let by = yield(message) { self.offer(by) }
        }
        return nil
      }
      group.addTask { try await body() }
      defer { group.cancelAll() }
      while let next = try await group.next() {
        if let value = next { return value }
      }
      throw CancellationError()
    }
  }

  /// Returns true once the deadline has passed, rechecking when an earlier one comes; false when cancelled first.
  func passed(now: () -> Date, sleep: (Duration) -> @Sendable () async throws -> Void) async -> Bool {
    while !Task.isCancelled {
      let (by, seen) = state.withLock { ($0.by, $0.offers) }
      guard let by else {
        await changed(since: seen)
        continue
      }
      let left = by.timeIntervalSince(now())
      guard left > 0 else { return true }
      let sleep = sleep(.seconds(left))
      await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await sleep() }
        group.addTask { await self.changed(since: seen) }
        await group.next()
        group.cancelAll()
      }
    }
    return false
  }

  /// Returns once an offer later than the `seen`-th has come, at once if one already has.
  private func changed(since seen: UInt64) async {
    let token = state.withLock { state in
      state.waiters += 1
      return state.waiters
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = state.withLock { state in
          guard !Task.isCancelled, state.offers == seen else { return true }
          state.changed[token] = continuation
          return false
        }
        if cancelled { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.changed.removeValue(forKey: token) }?.resume()
    }
  }
}
