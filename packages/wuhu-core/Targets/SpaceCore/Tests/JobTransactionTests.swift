import DeterministicDependencies
import Dispatch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDBSQLite
import Scratch
@testable import SpaceCore
import StructuredQueries
import Synchronization
import Testing
@testable import Wuwei
import struct Wuwei.Database
import WuweiQueries

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
  func begin(label: String = "writer.begin") throws -> any SharedTransaction {
    if signals.watching.withLock({ $0 }) { signals.events.continuation.yield("begin") }
    return try base.begin(label: label)
  }

  func write(label: String = "writer.write", _ body: (OpaquePointer) throws -> Void) throws {
    if signals.watching.withLock({ $0 }) { signals.events.continuation.yield("write") }
    try base.write(label: label, body)
  }

  func beginRead() throws -> any SharedReadTransaction { try base.beginRead() }
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

@Suite(.deterministicDependencies) struct JobTransactionTests {
  @Test func twoLanesAndAnOutsideCellCallWaitForTheHeldWriter() async throws {
    let folder = try ScratchFolder("job-transaction")
    let space = try Space.open(file: folder.url.appending(path: "space.sqlite"))
    let signals = TransactionSignals()
    defer { signals.events.continuation.finish() }
    let changes = space.database.changes
    let (jobChanges, jobWake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (outerChanges, outerWake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let stopJob = changes.subscribe(["transaction_job"], jobWake)
    let stopOuter = changes.subscribe(["wuwei_job"], outerWake)
    defer { stopJob(); stopOuter() }
    let database = WatchedDatabase(base: space.database, signals: signals)
    let worker = Worker(id: "transactions", storage: .shared(database), scheduler: LiveScheduler(), registrations: [.job(TransactionJob.self), .cell(TransactionCell.self)])
    worker.provide(signals)
    let cell = TransactionCell.ID("cell")
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
    let numbers = worker.job(TransactionJob.ID("holder")).db.rows(TransactionValue.order(by: \.n)).map(\.n)
    #expect(numbers == [1, 2, 4])
    var jobWakes = jobChanges.makeAsyncIterator()
    var outerWakes = outerChanges.makeAsyncIterator()
    #expect(await jobWakes.next() != nil)
    #expect(await outerWakes.next() != nil)
    try await space.close()
  }
}

extension JobTransactionTests {
  @Test func aFailedCommitAndARollbackBothReleaseTheWriter() async throws {
    let folder = try ScratchFolder("job-commit-failure")
    let changes = ChangeSource()
    let database = try WuweiDatabase(path: folder.url.appending(path: "space.sqlite").path, changes: changes)
    let (wakes, wake) = AsyncStream<Void>.makeStream()
    let stop = changes.subscribe(["probe"], wake)
    defer { stop() }
    try database.write { handle in
      #expect(sqlite3_exec(handle, "CREATE TABLE probe (n INTEGER)", nil, nil, nil) == SQLITE_OK)
    }
    try database.accessWriter(label: "test.writer") { _ = sqlite3_commit_hook($0, { _ in 1 }, nil) }
    let failed = try database.begin()
    try failed.access { handle in
      #expect(sqlite3_exec(handle, "INSERT INTO probe VALUES (1)", nil, nil, nil) == SQLITE_OK)
    }
    #expect { try failed.commit() } throws: { error in
      ((error as? TransactionEnded)?.cause as? SQLiteError)?.code == (SQLITE_CONSTRAINT | (2 << 8))
    }
    try database.accessWriter(label: "test.writer") { _ = sqlite3_commit_hook($0, nil, nil) }
    let rollback = try database.begin()
    try rollback.access { handle in
      #expect(sqlite3_exec(handle, "INSERT INTO probe VALUES (2)", nil, nil, nil) == SQLITE_OK)
    }
    rollback.rollback()
    let success = try database.begin()
    try success.access { handle in
      #expect(sqlite3_exec(handle, "INSERT INTO probe VALUES (3)", nil, nil, nil) == SQLITE_OK)
    }
    try success.commit()
    let kept = try database.beginRead().access { handle in
      var statement: OpaquePointer?
      #expect(sqlite3_prepare_v2(handle, "SELECT n FROM probe", -1, &statement, nil) == SQLITE_OK)
      defer { sqlite3_finalize(statement) }
      #expect(sqlite3_step(statement) == SQLITE_ROW)
      let value = sqlite3_column_int64(statement, 0)
      #expect(sqlite3_step(statement) == SQLITE_DONE)
      return value
    }
    #expect(kept == 3)
    wake.finish()
    var publications = 0
    for await _ in wakes { publications += 1 }
    #expect(publications == 1)
    database.closeReaders()
    try database.closeWriter()
  }

  @Test func aClosedWriterFailsBeforeParking() throws {
    let folder = try ScratchFolder("job-begin-failure")
    let database = try WuweiDatabase(path: folder.url.appending(path: "space.sqlite").path)
    try database.closeWriter()
    #expect(throws: SQLiteError.self) { _ = try database.begin() }
    database.closeReaders()
  }
}

@Table("transaction_job")
private struct TransactionValue {
  let owner: String
  let n: Int64
}
