import Foundation
@testable import SpaceCore
import SpaceFS
import Testing

@Suite struct ObserveResumeTests {
  @Test func replaysCommittedEventsAfterCursorThenContinuesLive() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a.md", "one")
    _ = try await space.writeText("/b.md", "two")

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(1), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    _ = try await space.writeText("/c.md", "three")
    let collected = await awaitItems(events, atLeast: 2)
    await settle()

    #expect(collected == [
      MutationEvent(group: .shared, path: "/b.md", rev: 2, kind: .write, entry: .file),
      MutationEvent(group: .shared, path: "/c.md", rev: 3, kind: .write, entry: .file),
    ])
  }

  @Test func everyRevArrivesExactlyOnceWhenWritesRaceTheSubscribe() async throws {
    let space = try makeSpace()
    let total = 20
    let writes = Task {
      for index in 1 ... total {
        _ = try await space.writeText("/f\(index).md", "content \(index)")
      }
    }

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    try await writes.value
    let collected = await awaitItems(events, atLeast: total)
    await settle()

    #expect(collected.count == total)
    #expect(collected.map(\.rev).sorted() == Array(1 ... total))
    #expect(Set(collected.map(\.path)).count == total)
  }

  @Test func replayFiltersByGlob() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/notes/a.md", "x")
    _ = try await space.writeText("/other.md", "y")

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "/notes/**", from: Rev(0), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    let collected = await awaitItems(events, atLeast: 1)
    await settle()

    #expect(collected == [MutationEvent(group: .shared, path: "/notes/a.md", rev: 1, kind: .write, entry: .file)])
  }

  @Test func cursorBeyondCurrentRevReplaysNothingAndStaysLive() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a.md", "one")

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(100), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    _ = try await space.writeText("/b.md", "two")
    let collected = await awaitItems(events, atLeast: 1)
    await settle()

    #expect(collected == [MutationEvent(group: .shared, path: "/b.md", rev: 2, kind: .write, entry: .file)])
  }

  @Test func tableOpsReachLiveSubscribersMatchingReplay() async throws {
    let space = try makeSpace()
    let table = try path("/t.table")

    let live = Collector<MutationEvent>()
    let liveStream = await space.observeFS(glob: "**", group: .shared)
    let liveConsumer = Task { for await event in liveStream { await live.append(event) } }
    defer { liveConsumer.cancel() }

    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer),
    ]), in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)
    _ = try await space.alterTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    let liveCollected = await awaitItems(live, atLeast: 3)
    await settle()

    let replayed = Collector<MutationEvent>()
    let replayStream = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
    let replayConsumer = Task { for await event in replayStream { await replayed.append(event) } }
    defer { replayConsumer.cancel() }
    let replayCollected = await awaitItems(replayed, atLeast: 3)
    await settle()

    #expect(liveCollected == [
      MutationEvent(group: .shared, path: "/t.table", rev: 1, kind: .write, entry: .table),
      MutationEvent(group: .shared, path: "/t.table", rev: 2, kind: .write, entry: .table),
      MutationEvent(group: .shared, path: "/t.table", rev: 3, kind: .write, entry: .table),
    ])
    #expect(replayCollected == liveCollected)
  }

  @Test func replayCarriesEntryKinds() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/notes/a.md", "x")
    _ = try await space.createTable(try path("/notes/t.table"), header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer),
    ]), in: .shared, acting: .shared)

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    let collected = await awaitItems(events, atLeast: 3)
    await settle()

    #expect(collected == [
      MutationEvent(group: .shared, path: "/notes", rev: 1, kind: .write, entry: .directory),
      MutationEvent(group: .shared, path: "/notes/a.md", rev: 1, kind: .write, entry: .file),
      MutationEvent(group: .shared, path: "/notes/t.table", rev: 2, kind: .write, entry: .table),
    ])
  }

  @Test func replayCollapsesMoveJournalRowsIntoOneEvent() async throws {
    let space = try makeSpace()
    _ = try await space.writeText("/a.md", "one")
    try await space.fs(.shared).move("/a.md", to: "/b.md")
    try await space.fs(.shared).delete("/b.md", ifMatch: nil)

    let events = Collector<MutationEvent>()
    let stream = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
    let consumer = Task { for await event in stream { await events.append(event) } }
    defer { consumer.cancel() }

    let collected = await awaitItems(events, atLeast: 3)
    await settle()

    #expect(collected == [
      MutationEvent(group: .shared, path: "/a.md", rev: 1, kind: .write, entry: .file),
      MutationEvent(group: .shared, path: "/b.md", from: "/a.md", rev: 2, kind: .move, entry: .file),
      MutationEvent(group: .shared, path: "/b.md", rev: 3, kind: .delete, entry: nil),
    ])
  }
}
