import struct SpaceContract.GroupID
import SpaceFS
import Synchronization

public struct FSCommit: Equatable, Sendable {
  public let group: GroupID
  public let rev: Int
  public let events: [MutationEvent]

  init(group: GroupID, rev: Int, events: [MutationEvent]) {
    precondition(!events.isEmpty && events.allSatisfy { $0.group == group && $0.rev == rev })
    self.group = group
    self.rev = rev
    self.events = events
  }
}

final class FSBroadcast: Sendable {
  private struct Subscriber {
    let group: GroupID
    let glob: String
    let continuation: AsyncStream<FSCommit>.Continuation
  }

  private struct State {
    var nextID: UInt64 = 0
    var subscribers: [UInt64: Subscriber] = [:]
  }

  private let state = Mutex(State())

  func subscribe(glob: String, group: GroupID) -> AsyncStream<FSCommit> {
    let (stream, continuation) = AsyncStream<FSCommit>.makeStream()
    let id = state.withLock { current -> UInt64 in
      current.nextID += 1
      current.subscribers[current.nextID] = Subscriber(group: group, glob: glob, continuation: continuation)
      return current.nextID
    }
    continuation.onTermination = { [weak self] _ in self?.remove(id) }
    return stream
  }

  func emit(_ commits: [FSCommit]) {
    state.withLock { current in
      for commit in commits {
        for subscriber in current.subscribers.values where subscriber.group == commit.group {
          let events = commit.events.filter { Self.matches(subscriber.glob, $0) }
          if !events.isEmpty {
            subscriber.continuation.yield(FSCommit(group: commit.group, rev: commit.rev, events: events))
          }
        }
      }
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

public extension AsyncStream where Element == FSCommit {
  var mutations: AsyncStream<MutationEvent> {
    AsyncStream<MutationEvent> { continuation in
      let task = Task {
        for await commit in self {
          for event in commit.events { continuation.yield(event) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
