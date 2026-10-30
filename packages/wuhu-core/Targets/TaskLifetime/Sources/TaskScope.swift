import protocol Clocks.NonsendingClock
import Logging
import Synchronization

public struct TaskScopeClosed: Error, Equatable {
  public init() {}
}

public final class TaskScope: Sendable {
  private struct Child: Sendable {
    let name: String
    let cancel: @Sendable () -> Void
    let wait: @Sendable () async -> Void
  }

  private enum State {
    case open(next: UInt64, children: [UInt64: Child])
    case closing([UInt64: Child])
    case closed
  }

  private let state = Mutex(State.open(next: 0, children: [:]))

  public init() {}

  public var liveTasks: [String] {
    state.withLock {
      switch $0 {
      case let .open(_, children): children.values.map(\.name).sorted()
      case let .closing(children): children.values.map(\.name).sorted()
      case .closed: []
      }
    }
  }

  @discardableResult
  public func run<Value: Sendable>(
    _ name: String,
    isolation: isolated (any Actor)? = #isolation,
    @_inheritActorContext @_implicitSelfCapture operation: @escaping @isolated(any) @Sendable () async -> Value,
  ) throws(TaskScopeClosed) -> Task<Value, Never> {
    try state.withLock { state throws(TaskScopeClosed) in
      guard case .open(let next, var children) = state else { throw TaskScopeClosed() }
      let task = Task { [self] in
        _ = isolation
        let value = await operation()
        finished(next)
        return value
      }
      children[next] = Child(name: name, cancel: { task.cancel() }, wait: { _ = await task.value })
      state = .open(next: next + 1, children: children)
      return task
    }
  }

  @discardableResult
  public func run<Value: Sendable>(
    _ name: String,
    isolation: isolated (any Actor)? = #isolation,
    @_inheritActorContext @_implicitSelfCapture operation: @escaping @isolated(any) @Sendable () async throws -> Value,
  ) throws(TaskScopeClosed) -> Task<Value, any Error> {
    try state.withLock { state throws(TaskScopeClosed) in
      guard case .open(let next, var children) = state else { throw TaskScopeClosed() }
      let task = Task { [self] in
        _ = isolation
        defer { finished(next) }
        return try await operation()
      }
      children[next] = Child(name: name, cancel: { task.cancel() }, wait: { _ = await task.result })
      state = .open(next: next + 1, children: children)
      return task
    }
  }

  public func bestEffort(
    _ name: String, within duration: Duration, clock: some NonsendingClock<Duration> = ContinuousClock(),
    isolation: isolated (any Actor)? = #isolation,
    operation: @escaping @Sendable () async throws -> Void,
  ) {
    do {
      try run(name) {
        do { try await withDeadline(duration, clock: clock, isolation: isolation, operation: operation) }
        catch { Logger(label: "task-lifetime").warning("Best-effort task failed", metadata: ["task": "\(name)", "error": "\(error)"]) }
      }
    } catch { Logger(label: "task-lifetime").warning("Best-effort task refused", metadata: ["task": "\(name)", "error": "\(error)"]) }
  }

  public func cancel() {
    let children = state.withLock { state -> [Child] in
      switch state {
      case let .open(_, children): Array(children.values)
      case let .closing(children): Array(children.values)
      case .closed: []
      }
    }
    for child in children { child.cancel() }
  }

  public func close() async {
    let children = state.withLock { state -> [Child] in
      switch state {
      case let .open(_, children):
        state = .closing(children)
        return Array(children.values)
      case let .closing(children): return Array(children.values)
      case .closed: return []
      }
    }
    for child in children { child.cancel() }
    // Draining remains mandatory when the owner's shutdown task is cancelled.
    await uncancellable("Drain children even when their owner is cancelled") {
      for child in children { await child.wait() }
    }
    state.withLock { $0 = .closed }
  }

  private func finished(_ id: UInt64) {
    state.withLock { state in
      switch state {
      case .open(let next, var children):
        children[id] = nil
        state = .open(next: next, children: children)
      case .closing(var children):
        children[id] = nil
        state = .closing(children)
      case .closed: break
      }
    }
  }
}
