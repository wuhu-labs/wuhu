import Synchronization

/// The tables the space's writer wrote, and who wants to hear of them: each committed transaction wakes the subscriptions to a table it touched, once, and a rollback wakes nobody.
final class ChangeSource: Sendable {
  private struct Subscription {
    let tables: Set<String>
    let wakes: AsyncStream<Void>.Continuation
  }

  private struct State {
    var subscriptions: [Int: Subscription] = [:]
    var nextSubscription = 0
  }

  private let state = Mutex(State())

  func publish(_ tables: Set<String>) {
    let woken = state.withLock { state in
      state.subscriptions.values.filter { !$0.tables.isDisjoint(with: tables) }.map(\.wakes)
    }
    for wakes in woken { wakes.yield(()) }
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
