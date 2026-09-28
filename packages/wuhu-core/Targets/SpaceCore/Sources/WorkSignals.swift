import SessionDomain
import Synchronization

final class WorkSignals: Sendable {
  private struct Subscriber {
    var pending: [SessionID] = []
    let doorbell: AsyncStream<Void>.Continuation
  }

  private struct State {
    var nextID: UInt64 = 0
    var subscribers: [UInt64: Subscriber] = [:]
  }

  private let state = Mutex(State())

  func post(_ session: SessionID) {
    let bells = state.withLock { state -> [AsyncStream<Void>.Continuation] in
      var bells: [AsyncStream<Void>.Continuation] = []
      for id in state.subscribers.keys where !state.subscribers[id]!.pending.contains(session) {
        state.subscribers[id]!.pending.append(session)
        bells.append(state.subscribers[id]!.doorbell)
      }
      return bells
    }
    for bell in bells {
      bell.yield(())
    }
  }

  func subscribe() -> WorkSignalSubscription {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = state.withLock { state -> UInt64 in
      state.nextID += 1
      state.subscribers[state.nextID] = Subscriber(doorbell: continuation)
      return state.nextID
    }
    continuation.onTermination = { [weak self] _ in
      self?.state.withLock { $0.subscribers[id] = nil }
    }
    return WorkSignalSubscription(signals: self, id: id, doorbell: stream)
  }

  func take(_ id: UInt64) -> SessionID? {
    state.withLock { state in
      guard let first = state.subscribers[id]?.pending.first else { return nil }
      state.subscribers[id]!.pending.removeFirst()
      return first
    }
  }

  func repost(_ id: UInt64, _ session: SessionID) {
    let bell = state.withLock { state -> AsyncStream<Void>.Continuation? in
      guard var subscriber = state.subscribers[id], !subscriber.pending.contains(session) else { return nil }
      subscriber.pending.append(session)
      state.subscribers[id] = subscriber
      return subscriber.doorbell
    }
    bell?.yield(())
  }
}

public struct WorkSignalSubscription: AsyncSequence, Sendable {
  public typealias Element = SessionID

  let signals: WorkSignals
  let id: UInt64
  let doorbell: AsyncStream<Void>

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(signals: signals, id: id, bells: doorbell.makeAsyncIterator())
  }

  public func repost(_ session: SessionID) {
    signals.repost(id, session)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    let signals: WorkSignals
    let id: UInt64
    var bells: AsyncStream<Void>.AsyncIterator

    public mutating func next() async -> SessionID? {
      while true {
        if let session = signals.take(id) { return session }
        guard await bells.next() != nil else { return nil }
      }
    }
  }
}
