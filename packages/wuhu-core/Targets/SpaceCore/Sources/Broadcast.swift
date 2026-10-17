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
    var closed = false
    var nextID: UInt64 = 0
    var subscribers: [UInt64: Subscriber] = [:]
  }

  private let state = Mutex(State())
  private let beforeDelivery: @Sendable () -> Void
  private let beforeRemoval: @Sendable () -> Void

  init(
    beforeDelivery: @escaping @Sendable () -> Void = {},
    beforeRemoval: @escaping @Sendable () -> Void = {},
  ) {
    self.beforeDelivery = beforeDelivery
    self.beforeRemoval = beforeRemoval
  }

  func subscribe(glob: String, group: GroupID) -> AsyncStream<FSCommit> {
    let (stream, continuation) = AsyncStream<FSCommit>.makeStream()
    let id = state.withLock { current -> UInt64? in
      guard !current.closed else { return nil }
      current.nextID += 1
      current.subscribers[current.nextID] = Subscriber(group: group, glob: glob, continuation: continuation)
      return current.nextID
    }
    if let id { continuation.onTermination = { [weak self] _ in self?.remove(id) } }
    else { continuation.finish() }
    return stream
  }

  func close() {
    let subscribers = state.withLock { state in
      let current = Array(state.subscribers.values)
      state.closed = true
      state.subscribers.removeAll()
      return current
    }
    for subscriber in subscribers { subscriber.continuation.finish() }
  }

  func emit(_ commits: [FSCommit]) {
    // Substrate.writeEmitting holds the serialized database writer through delivery.
    let deliveries = state.withLock { current in
      commits.flatMap { commit in
        current.subscribers.values.compactMap { subscriber -> (AsyncStream<FSCommit>.Continuation, FSCommit)? in
          guard subscriber.group == commit.group else { return nil }
          let events = commit.events.filter { Self.matches(subscriber.glob, $0) }
          guard !events.isEmpty else { return nil }
          return (subscriber.continuation, FSCommit(group: commit.group, rev: commit.rev, events: events))
        }
      }
    }
    beforeDelivery()
    for (continuation, commit) in deliveries {
      continuation.yield(commit)
    }
  }

  private func remove(_ id: UInt64) {
    beforeRemoval()
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
    let source = Mutations(commits: self)
    return AsyncStream<MutationEvent>(unfolding: { await source.next() })
  }
}

private actor Mutations {
  private var commits: AsyncStream<FSCommit>.Iterator?
  private var pending: Array<MutationEvent>.Iterator = [].makeIterator()

  init(commits: AsyncStream<FSCommit>) { self.commits = commits.makeAsyncIterator() }

  func next() async -> MutationEvent? {
    while true {
      if let event = pending.next() { return event }
      guard var commits = self.commits else { return nil }
      self.commits = nil
      guard let commit = await commits.next(isolation: self) else { return nil }
      self.commits = commits
      pending = commit.events.makeIterator()
    }
  }
}
