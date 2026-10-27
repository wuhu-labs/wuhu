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
  @Test(arguments: ["ABORT", "ROLLBACK"]) func failedReceiptEmitsNeitherNowNorOnTheNextTransaction(action: String) async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let session = try await store.createSession(group: .shared, title: "writer", kind: .agent, createdBy: "morgan", model: .test)
      try await space.writer.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_receipt BEFORE INSERT ON session_receipts BEGIN SELECT RAISE(\(action), 'receipt failure'); END")
      }
      let stream = await space.observeFS(glob: "**", group: .shared)
      let commits = Collector<FSCommit>()
      let consumer = Task { for await commit in stream { await commits.append(commit) } }
      defer { consumer.cancel() }
      await #expect(throws: DatabaseError.self) {
        _ = try await store.recordedSpaceWrite(
          session, toolCallID: ToolCallID("failed"), path: "/failed.md", in: .shared,
          content: bytes("must roll back"), ifMatchRev: nil,
        ) { rev in .write(.init(path: "/failed.md", revision: .journal(rev))) }
      }
      #expect(try await space.currentRevision() == 0)
      await #expect(throws: SpaceError.notFound("/failed.md")) { _ = try await space.readText("/failed.md") }
      #expect(try await store.receipt(.session(session), toolCallID: ToolCallID("failed")) == nil)
      // This successful non-filesystem transaction must not fire an orphaned emission.
      try await space.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_receipt") }
      await settle()
      #expect(await commits.items.isEmpty)
      _ = try await space.writeText("/success.md", "committed")
      let received = try await awaitItems(commits, atLeast: 1)
      await settle()
      #expect(await commits.items.count == 1)
      #expect(received.map(\.rev) == [1])
      #expect(received.flatMap(\.events).map(\.path) == ["/success.md"])
    }
  }

  @Test func deferredExternalCheckoutRetriesAndEmitsExactlyOneCommittedBatch() async throws {
    let folder = try ScratchFolder("observe-deferred")
    let space = try Space.inMemory(objects: FileSystemObjectStore(root: folder.url))
    let original = String(repeating: "x", count: BlobStore.inlineThreshold + 1)
    _ = try await space.writeText("/external.md", original)
    _ = try await space.writeText("/external.md", "newer")
    let stream = await space.observeFS(glob: "**", group: .shared)
    let commits = Collector<FSCommit>()
    let consumer = Task { for await commit in stream { await commits.append(commit) } }
    defer { consumer.cancel() }
    let observer = Rollbacks()
    try await space.writer.writeWithoutTransaction { db in db.add(transactionObserver: observer, extent: .databaseLifetime) }
    let (rev, _) = try await space.checkout(try path("/external.md"), rev: Rev(1), in: .shared, acting: .shared)
    #expect(observer.count == 1)
    #expect(rev.value == 3)
    #expect(try await space.currentRevision() == 3)
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
