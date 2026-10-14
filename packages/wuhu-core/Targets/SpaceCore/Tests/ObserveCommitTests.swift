import Foundation
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct ObserveCommitTests {
  @Test func recursiveDeleteIsOneFilteredCommitLiveAndReplayed() async throws {
    let space = try makeSpace()
    for name in ["a", "b", "c"] { _ = try await space.writeText("/dir/\(name).md", name) }
    let start = try await space.currentRevision()
    let stream = await space.observeFS(glob: "/dir/**", group: .shared)
    try await space.fs(.shared).delete("/dir", ifMatch: nil)
    var live = stream.makeAsyncIterator()
    let commit = try #require(await live.next())
    #expect(commit.rev == start + 1)
    #expect(commit.group == .shared)
    #expect(commit.events.count == 3)
    #expect(Set(commit.events.map(\.path)) == ["/dir/a.md", "/dir/b.md", "/dir/c.md"])
    #expect(commit.events.allSatisfy { $0.kind == .delete && $0.rev == commit.rev })
    let replay = await space.observeFS(glob: "/dir/**", from: Rev(start), group: .shared)
    var iterator = replay.makeAsyncIterator()
    let replayed = try #require(await iterator.next())
    #expect(replayed.rev == commit.rev)
    #expect(Set(replayed.events.map(\.path)) == Set(commit.events.map(\.path)))
    #expect(replayed.events.count == commit.events.count)
  }

  @Test(.timeLimit(.minutes(1))) func stalledSubscriberDoesNotBlockTheWriterOrDropBufferedCommits() async throws {
    let space = try makeSpace()
    let stalled = await space.observeFS(glob: "**", group: .shared)
    for index in 1 ... 200 {
      _ = try await space.writeText("/file\(index)", "content")
    }
    #expect(try await space.currentRevision() == 200)
    var iterator = stalled.makeAsyncIterator()
    for index in 1 ... 200 {
      let commit = try #require(await iterator.next())
      #expect(commit.rev == index)
      #expect(commit.events.count == 1)
    }
  }

  @Test func unmatchedCommitYieldsNothingAndMatchingCommitKeepsOnlyMatchingEvents() async throws {
    let space = try makeSpace()
    let stream = await space.observeFS(glob: "/dir/a*", group: .shared)
    _ = try await space.writeText("/elsewhere", "x")
    _ = try await space.writeText("/dir/b.md", "b")
    _ = try await space.writeText("/dir/a.md", "a")
    try await space.fs(.shared).delete("/dir", ifMatch: nil)
    var iterator = stream.makeAsyncIterator()
    let write = try #require(await iterator.next())
    let delete = try #require(await iterator.next())
    #expect(write.rev == 3)
    #expect(delete.rev == 4)
    #expect(write.events.map(\.path) == ["/dir/a.md"])
    #expect(delete.events.map(\.path) == ["/dir/a.md"])
  }

  @Test func hundredDeleteWriteRacesKeepCommitsWholeAndOrdered() async throws {
    let space = try makeSpace()
    for race in 0 ..< 100 {
      for name in ["a", "b", "c"] { _ = try await space.writeText("/dir\(race)/\(name)", name) }
    }
    let start = try await space.currentRevision()
    let stream = await space.observeFS(glob: "**", group: .shared)
    let commits = Collector<FSCommit>()
    let consumer = Task { for await commit in stream { await commits.append(commit) } }
    defer { consumer.cancel() }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      for race in 0 ..< 100 {
        tasks.addTask { try await space.fs(.shared).delete("/dir\(race)", ifMatch: nil) }
        tasks.addTask { _ = try await space.writeText("/other\(race)", "x") }
      }
      try await tasks.waitForAll()
    }
    let received = try await awaitItems(commits, atLeast: 200)
    #expect(received.count == 200)
    #expect(received.map(\.rev) == Array((start + 1) ... (start + 200)))
    #expect(received.filter { $0.events.first?.kind == .delete }.count == 100)
    for commit in received {
      #expect(commit.events.allSatisfy { $0.rev == commit.rev })
      if commit.events.first?.kind == .delete { #expect(commit.events.count == 4) }
    }
  }

  @Test func replayCeilingDeduplicatesWholeCommitsWhenDeletesRaceSubscription() async throws {
    let space = try makeSpace()
    for race in 0 ..< 100 {
      for name in ["a", "b", "c"] { _ = try await space.writeText("/dir\(race)/\(name)", name) }
    }
    let start = try await space.currentRevision()
    let writes = Task {
      for race in 0 ..< 100 { try await space.fs(.shared).delete("/dir\(race)", ifMatch: nil) }
    }
    let stream = await space.observeFS(glob: "**", from: Rev(start), group: .shared)
    let commits = Collector<FSCommit>()
    let consumer = Task { for await commit in stream { await commits.append(commit) } }
    defer { consumer.cancel() }
    try await writes.value
    let received = try await awaitItems(commits, atLeast: 100)
    await settle()
    #expect(await commits.items.count == 100)
    #expect(received.map(\.rev) == Array((start + 1) ... (start + 100)))
    #expect(received.allSatisfy { $0.events.count == 4 && $0.events.allSatisfy { $0.kind == .delete } })
  }
}
