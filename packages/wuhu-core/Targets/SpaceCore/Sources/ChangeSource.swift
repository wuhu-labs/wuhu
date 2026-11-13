import Synchronization

/// The tables the space's writer wrote, and who wants to hear of them: each committed transaction wakes the subscriptions to a table it touched, once, and a rollback wakes nobody.
final class ChangeSource: Sendable {
  private struct Subscription {
    let tables: Set<String>
    let wakes: AsyncStream<Void>.Continuation
  }

  private struct State {
    var touched: Set<String> = []
    var subscriptions: [Int: Subscription] = [:]
    var nextSubscription = 0
  }

  private let state = Mutex(State())

  /// A statement of the open transaction wrote `table`.
  func wrote(_ table: String) {
    state.withLock { _ = $0.touched.insert(table) }
  }

  /// The open transaction committed. The wakes leave after the lock is released: a yield runs no subscriber code.
  func committed() {
    let woken = state.withLock { state -> [AsyncStream<Void>.Continuation] in
      let touched = state.touched
      state.touched.removeAll()
      guard !touched.isEmpty else { return [] }
      return state.subscriptions.values.filter { !$0.tables.isDisjoint(with: touched) }.map(\.wakes)
    }
    for wakes in woken { wakes.yield(()) }
  }

  /// The open transaction rolled back: what it wrote is nobody's news.
  func rolledBack() {
    state.withLock { $0.touched.removeAll() }
  }

  /// A subscription to `tables`, in the shape ``RegionSource`` has: what wakes it, and what cancels it.
  func subscribe(_ tables: [String], _ wakes: AsyncStream<Void>.Continuation) -> @Sendable () -> Void {
    let subscription = Subscription(tables: Set(tables), wakes: wakes)
    let id = state.withLock { state -> Int in
      state.nextSubscription += 1
      state.subscriptions[state.nextSubscription] = subscription
      return state.nextSubscription
    }
    return { self.state.withLock { $0.subscriptions[id] = nil } }
  }
}
