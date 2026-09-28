import struct SpaceContract.GroupID
import SpaceFS
import Synchronization

final class FSBroadcast: Sendable {
  private struct Subscriber {
    let group: GroupID
    let glob: String
    let continuation: AsyncStream<MutationEvent>.Continuation
  }

  private struct State {
    var nextID: UInt64 = 0
    var subscribers: [UInt64: Subscriber] = [:]
  }

  private let state = Mutex(State())

  func subscribe(glob: String, group: GroupID) -> AsyncStream<MutationEvent> {
    let (stream, continuation) = AsyncStream<MutationEvent>.makeStream()
    let id = state.withLock { current -> UInt64 in
      current.nextID += 1
      current.subscribers[current.nextID] = Subscriber(group: group, glob: glob, continuation: continuation)
      return current.nextID
    }
    continuation.onTermination = { [weak self] _ in self?.remove(id) }
    return stream
  }

  func emit(_ event: MutationEvent) {
    let targets = state.withLock { current in
      current.subscribers.values.filter { $0.group == event.group && Self.matches($0.glob, event) }
    }
    for subscriber in targets {
      subscriber.continuation.yield(event)
    }
  }

  private func remove(_ id: UInt64) {
    state.withLock { $0.subscribers[id] = nil }
  }

  static func matches(_ glob: String, _ event: MutationEvent) -> Bool {
    if Glob.matches(glob, event.path) { return true }
    if let from = event.from { return Glob.matches(glob, from) }
    return false
  }
}
