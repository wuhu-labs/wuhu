import Dispatch
@testable import SpaceCore
import SpaceFS
import Testing

@MainActor @Suite struct BroadcastCancellationTests {
  @Test func cancellationDuringDeliveryDoesNotHoldTheBroadcastLock() async {
    let cancellationEntered = DispatchSemaphore(value: 0)
    let ready = AsyncStream<Void>.makeStream()
    let selected = AsyncStream<Void>.makeStream()
    let broadcast = FSBroadcast(
      beforeDelivery: {
        selected.continuation.yield()
        cancellationEntered.wait()
      },
      beforeRemoval: { cancellationEntered.signal() },
    )
    let survivor = broadcast.subscribe(glob: "**", group: .shared)
    let stream = broadcast.subscribe(glob: "**", group: .shared)
    let consumer = Task { @MainActor in
      ready.continuation.yield()
      for await _ in stream {}
    }
    for await _ in ready.stream { break }
    let commit = FSCommit(group: .shared, rev: 1, events: [
      MutationEvent(group: .shared, path: "/a.md", rev: 1, kind: .write, entry: .file),
    ])
    let producer = Task.detached { broadcast.emit([commit]) }
    for await _ in selected.stream { break }
    let cancellation = Task.detached { consumer.cancel() }
    await producer.value
    await cancellation.value
    await consumer.value
    var iterator = survivor.makeAsyncIterator()
    #expect(await iterator.next() == commit)
  }

  @Test func concurrentWritesDeliverInDatabaseCommitOrder() async throws {
    let space = try Space.inMemory()
    let stream = await space.observeFS(glob: "/concurrent/**", group: .shared)
    let consumer = Task { () -> [Int] in
      var revisions: [Int] = []
      for await commit in stream {
        revisions.append(commit.rev)
        if revisions.count == 32 { break }
      }
      return revisions
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0 ..< 32 {
        group.addTask {
          _ = try await space.writeText("/concurrent/\(index).md", "\(index)")
        }
      }
      try await group.waitForAll()
    }
    #expect(await consumer.value == Array(1 ... 32))
  }
}
