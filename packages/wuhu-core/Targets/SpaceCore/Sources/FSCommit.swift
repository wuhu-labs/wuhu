import struct SpaceContract.GroupID
import SpaceFS

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
