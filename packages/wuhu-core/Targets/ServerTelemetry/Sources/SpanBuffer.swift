import Dependencies
import Logging
import Synchronization

public final class SpanBuffer: Sendable {
  private struct State {
    var spans: [FinishedSpan] = []
    var warned = false
    var dropped = 0
    var closed = false
    var exporting = false
    var waiters: [AsyncStream<Void>.Continuation] = []
  }

  private enum Next {
    case batch([FinishedSpan]), wait(AsyncStream<Void>), empty
  }

  private let state = Mutex(State())
  private let capacity: Int
  private let logger = Logger(label: "wuhu.telemetry")

  public init(capacity: Int = 1024) { precondition(capacity > 0); self.capacity = capacity }

  public var pending: Int { state.withLock { $0.spans.count } }
  public var dropped: Int { state.withLock { $0.dropped } }

  public func append(_ span: FinishedSpan) {
    let warn = state.withLock { state in
      guard !state.closed, state.spans.count < capacity else {
        state.dropped += 1
        let warn = !state.warned
        state.warned = true
        return warn
      }
      state.spans.append(span)
      return false
    }
    if warn { logger.warning("Telemetry queue unavailable; dropping spans") }
  }

  public func flush(export: @Sendable ([FinishedSpan]) async throws -> Void) async {
    guard let batch = await takeBatch() else { return }
    defer {
      let waiters = state.withLock { state in
        state.exporting = false
        defer { state.waiters = [] }
        return state.waiters
      }
      for waiter in waiters { waiter.finish() }
    }
    do {
      try await export(batch)
      state.withLock { $0.warned = false }
    } catch {
      let warn = state.withLock { state in
        if Task.isCancelled, !state.closed {
          let kept = Array(batch.prefix(max(0, capacity - state.spans.count)))
          state.spans.insert(contentsOf: kept, at: 0)
          state.dropped += batch.count - kept.count
          return false
        }
        state.dropped += batch.count + state.spans.count
        state.spans.removeAll(keepingCapacity: true)
        let warn = !state.warned
        state.warned = true
        return warn
      }
      if warn { logger.warning("Telemetry export unavailable; dropping spans") }
    }
  }

  private func takeBatch() async -> [FinishedSpan]? {
    while !Task.isCancelled {
      let next: Next = state.withLock { state in
        if state.exporting {
          let (stream, continuation) = AsyncStream<Void>.makeStream()
          state.waiters.append(continuation)
          return .wait(stream)
        }
        guard !state.spans.isEmpty else { return .empty }
        let batch = Array(state.spans.prefix(64))
        state.spans.removeFirst(batch.count)
        state.exporting = true
        return .batch(batch)
      }
      switch next {
      case let .batch(batch): return batch
      case let .wait(stream): for await _ in stream {}
      case .empty: return nil
      }
    }
    return nil
  }

  public func run(export: @escaping @Sendable ([FinishedSpan]) async throws -> Void) async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled, !state.withLock({ $0.closed }) {
      do { try await clock.sleep(for: .seconds(1)) } catch { return }
      guard !state.withLock({ $0.closed }) else { return }
      await flush(export: export)
    }
  }

  public func shutdown(timeout: Duration = .seconds(2), export: @escaping @Sendable ([FinishedSpan]) async throws -> Void) async {
    let first = state.withLock { state in
      guard !state.closed else { return false }
      state.closed = true
      return true
    }
    guard first else { return }
    @Dependency(\.continuousClock) var clock
    await Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          repeat { await self.flush(export: export) } while self.pending > 0 && !Task.isCancelled
        }
        group.addTask { [clock] in try? await clock.sleep(for: timeout) }
        _ = await group.next()
        group.cancelAll()
      }
      self.state.withLock { state in
        state.dropped += state.spans.count
        state.spans.removeAll()
      }
    }.value
  }
}
