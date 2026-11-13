import DeterministicDependencies
import Foundation
import GRDB
import KeelObjectStore
import Scratch
import SessionDomain
@testable import SpaceCore
import SpaceFS
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct ObserveTransactionTests {
  @Test func externalCheckoutFetchesBeforeItsTransactionAndEmitsOneCommit() async throws {
    let folder = try ScratchFolder("observe-deferred")
    let space = try Space.inMemory(objects: FileSystemObjectStore(root: folder.url))
    let original = String(repeating: "x", count: Bucket.inlineThreshold + 1)
    _ = try await space.writeText("/external.md", original)
    _ = try await space.writeText("/external.md", "newer")
    let stream = try await space.observeFS(glob: "**", group: .shared)
    let commits = Collector<FSCommit>()
    let consumer = Task { for await commit in stream { await commits.append(commit) } }
    defer { consumer.cancel() }
    let observer = Rollbacks()
    try await space.writer.writeWithoutTransaction { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
    let (rev, _) = try await space.checkout(try path("/external.md"), rev: Rev(1), in: .shared, acting: .shared)
    #expect(observer.count == 0, "the old bytes are fetched before the transaction that writes them")
    #expect(rev.value == 3)
    #expect(try await space.currentRevision(in: .shared) == 3)
    #expect(try await space.readText("/external.md") == original)
    let received = try await awaitItems(commits, atLeast: 1)
    await settle()
    #expect(await commits.items.count == 1)
    #expect(received.map(\.rev) == [3])
    #expect(received.flatMap(\.events) == [MutationEvent(group: .shared, path: "/external.md", rev: 3, kind: .write, entry: .file)])
  }
}

private final class Rollbacks: TransactionObserver, Sendable {
  private let rolledBack = Mutex(0)
  var count: Int { rolledBack.withLock { $0 } }
  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { false }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidCommit(_: Database) {}
  func databaseDidRollback(_: Database) { rolledBack.withLock { $0 += 1 } }
}
