import DeterministicDependencies
import Dispatch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import Scratch
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei
import struct Wuwei.Database

private final class TransactionSignals: Sendable {
  let holder = DispatchSemaphore(value: 0)
  let other = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let events = AsyncStream<String>.makeStream()
  let watching = Mutex(false)
  let completed = Mutex<Set<String>>([])

  func enterStretch(holder: Bool) { (holder ? self.holder : other).wait() }
  func holdStretch() { release.wait() }
}

private struct WatchedDatabase: SharedDatabase {
  let base: WuweiDatabase
  let signals: TransactionSignals
  func begin() throws -> any SharedTransaction {
    if signals.watching.withLock({ $0 }) { signals.events.continuation.yield("begin") }
    return try base.begin()
  }

  func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws {
    if signals.watching.withLock({ $0 }) { signals.events.continuation.yield("write") }
    try base.write(body)
  }

  func read(_ body: (OpaquePointer) throws -> Void) throws { try base.read(body) }
  func execute(_ sql: String, _ arguments: [Value], on host: AnyObject?) throws -> Bool {
    try base.execute(sql, arguments, on: host)
  }
}

@Cell private struct TransactionCell {
  static let schema = ["CREATE TABLE transaction_cell (\(ownerColumn), n INTEGER)"]
  mutating func write() throws {
    try db.execute("INSERT INTO transaction_cell (n) VALUES (3)")
  }
}

@Job private struct TransactionJob {
  typealias Params = Bool
  typealias Message = Never
  static let schema = ["CREATE TABLE transaction_job (\(ownerColumn), n INTEGER UNIQUE)"]
  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    let signals = ctx.dependency(TransactionSignals.self)
    let holder = ctx.params
    signals.events.continuation.yield(holder ? "holderReady" : "otherReady")
    signals.enterStretch(holder: holder)
    try db.execute("INSERT INTO transaction_job (n) VALUES (?)", .integer(holder ? 1 : 2))
    if holder {
      #expect(ctx.job(id).db.one("SELECT n FROM transaction_job WHERE owner = cell()") == 1)
      do { try db.execute("INSERT INTO transaction_job (n) VALUES (1)") }
      catch is ConstraintViolation {}
      signals.events.continuation.yield("held")
      signals.holdStretch()
      try db.execute("INSERT INTO transaction_job (n) VALUES (4)")
    }
    let label = holder ? "holder" : "other"
    try await ctx.effect { signals.completed.withLock { _ = $0.insert(label) } }
    return .done
  }
}

private final class TransactionPokes: TransactionObserver, Sendable {
  let poke: @Sendable () -> Void
  let commits = Mutex(0)
  init(poke: @escaping @Sendable () -> Void) { self.poke = poke }
  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: GRDB.Database) {}
  func databaseDidCommit(_: GRDB.Database) {
    commits.withLock { $0 += 1 }
    poke()
  }
}

@Suite(.deterministicDependencies) struct JobTransactionTests {
  @Test func twoLanesAndAnOutsideCellCallWaitForTheHeldWriterAndCommitHooksOnlySchedule() async throws {
    let folder = try ScratchFolder("job-transaction")
    let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
    let signals = TransactionSignals()
    defer { signals.events.continuation.finish() }
    let writer = await space.writer
    let database = WatchedDatabase(base: try WuweiDatabase(writer: writer), signals: signals)
    let worker = Worker(id: "transactions", storage: .shared(database), scheduler: LiveScheduler(), registrations: [.job(TransactionJob.self), .cell(TransactionCell.self)])
    worker.provide(signals)
    let cell = TransactionCell.ID("cell")
    let observer = TransactionPokes { worker.poke(cell.recipient) }
    await space.writer.add(transactionObserver: observer)
    var events = signals.events.stream.makeAsyncIterator()
    try worker.create(TransactionJob.ID("holder"), params: true)
    try worker.create(TransactionJob.ID("other"), params: false)
    var ready: Set<String> = []
    while ready.count < 2 { ready.insert(await events.next()!) }
    #expect(ready == ["holderReady", "otherReady"])
    signals.holder.signal()
    #expect(await events.next() == "held")
    signals.watching.withLock { $0 = true }
    signals.other.signal()
    #expect(await events.next() == "begin")
    let call = Task { try await worker.call(cell) { try $0.write(); return 3 } }
    #expect(await events.next() == "write")
    #expect(signals.completed.withLock { $0.isEmpty })
    signals.release.signal()
    #expect(try await call.value == 3)
    await worker.quiesce()
    worker.release()
    #expect(signals.completed.withLock { $0 } == ["holder", "other"])
    #expect(observer.commits.withLock { $0 } > 0)
    let numbers = try await space.writer.read { try Int.fetchAll($0, sql: "SELECT n FROM transaction_job ORDER BY n") }
    #expect(numbers == [1, 2, 4])
    try database.base.reader.close()
    try await space.close()
  }
}

private struct RefusedCommit: Error {}

private final class CommitRefusal: TransactionObserver, Sendable {
  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: GRDB.Database) {}
  func databaseDidCommit(_: GRDB.Database) {}
  func databaseWillCommit() throws { throw RefusedCommit() }
}

extension JobTransactionTests {
  @Test func aFailedCommitAndARollbackBothReleaseTheWriter() throws {
    let folder = try ScratchFolder("job-commit-failure")
    let writer = try DatabaseQueue(path: folder.url.appending(path: "space.sqlite").path)
    let database = try WuweiDatabase(writer: writer)
    try writer.write { try $0.execute(sql: "CREATE TABLE probe (n INTEGER)") }
    let refusal = CommitRefusal()
    writer.add(transactionObserver: refusal)
    let failed = try database.begin()
    try failed.access { _, host in _ = try database.execute("INSERT INTO probe VALUES (1)", [], on: host) }
    #expect(throws: RefusedCommit.self) { try failed.commit() }
    writer.remove(transactionObserver: refusal)
    let rollback = try database.begin()
    try rollback.access { _, host in _ = try database.execute("INSERT INTO probe VALUES (2)", [], on: host) }
    rollback.rollback()
    let success = try database.begin()
    try success.access { _, host in _ = try database.execute("INSERT INTO probe VALUES (3)", [], on: host) }
    try success.commit()
    #expect(try writer.read { try Int.fetchAll($0, sql: "SELECT n FROM probe") } == [3])
    try database.reader.close()
    try writer.close()
  }

  @Test func aClosedWriterFailsBeforeParking() throws {
    let folder = try ScratchFolder("job-begin-failure")
    let writer = try DatabaseQueue(path: folder.url.appending(path: "space.sqlite").path)
    let database = try WuweiDatabase(writer: writer)
    try writer.close()
    #expect(throws: DatabaseError.self) { _ = try database.begin() }
    try database.reader.close()
  }
}
