import ControlledTime
import Dependencies
import DeterministicDependencies
import Dispatch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDBSQLite
import JSONValue
import Logging
import Scratch
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Synchronization
import Testing

/// The space's one observation job: the client streams are its sockets, so they follow it across a rollover and stop where it is not hosted.
@Suite(.deterministicDependencies) struct ObservationJobTests {
  private func makeTable(_ space: Space) async throws -> SpacePath {
    let table = try path("/t.table")
    _ = try await space.createTable(table, header: TableHeader(columns: [
      TableColumn(name: "n", type: .integer), TableColumn(name: "s", type: .text),
    ]), in: .shared, acting: .shared)
    return table
  }

  @Test func aRowsStreamStartsWithTheRowsThenOnlyChangedOnes() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let snapshots = Collector<Rows>()
    let stream = try space.observeRows("SELECT n FROM \"/t.table\" ORDER BY n", throttle: .zero, as: .shared(.publicReader))
    let consumer = Task { do { for try await rows in stream { await snapshots.append(rows) } } catch {} }
    defer { consumer.cancel() }

    let first = try await awaitItems(snapshots, atLeast: 1)
    try #require(first.count == 1)
    #expect(first[0].rows.isEmpty)

    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    let added = try await awaitItems(snapshots, atLeast: 2)
    #expect(added[1].rows == [[.integer(1)]])

    // A write the statement does not show is silent: the frame that follows it is the next changed one, not an unchanged snapshot.
    let ids = try await space.query("SELECT \"id\" FROM \"/t.table\"")
    guard case let .integer(id) = ids.rows[0][0] else {
      Issue.record("no id")
      return
    }
    _ = try await space.mutateRows(table, [.update(id: id, [.integer(1), .string("changed")])], in: .shared, acting: .shared)
    _ = try await space.mutateRows(table, [.insert([.integer(2), .string("b")])], in: .shared, acting: .shared)
    let shown = try await awaitItems(snapshots, atLeast: 3)
    #expect(shown[2].rows == [[.integer(1)], [.integer(2)]])
  }

  @Test func aStreamWaitingOutItsThrottleDoesNotDelayAnother() async throws {
    let clock = VirtualClock()
    let space = try makeSpace(clock: clock)
    let table = try await makeTable(space)

    let slow = Collector<Rows>()
    let slowStream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .seconds(10), as: .shared(.publicReader))
    let slowConsumer = Task { do { for try await rows in slowStream { await slow.append(rows) } } catch {} }
    defer { slowConsumer.cancel() }
    let fast = Collector<Rows>()
    let fastStream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .zero, as: .shared(.publicReader))
    let fastConsumer = Task { do { for try await rows in fastStream { await fast.append(rows) } } catch {} }
    defer { fastConsumer.cancel() }
    _ = try await awaitItems(slow, atLeast: 1)
    _ = try await awaitItems(fast, atLeast: 1)

    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    // The slow watch is in its throttle before anything is asserted on it or the clock moves.
    try await clock.sleeping(where: { $0 == .seconds(10) })
    _ = try await awaitItems(fast, atLeast: 2)
    #expect(await slow.items.count == 1)

    await clock.advance(by: .seconds(10))
    #expect(try await awaitItems(slow, atLeast: 2).last?.rows == [[.integer(1)]])
  }

  @Test func aRefusedStatementClosesItsStream() async throws {
    let space = try makeSpace()
    let stream = try space.observeRows("SELECT rev FROM revisions", throttle: .zero, as: .shared(.publicReader))
    var frames = 0
    for try await _ in stream { frames += 1 }
    #expect(frames == 0)
  }

  @Test func aFileStreamEndsWhenTheReaderLosesTheGroup() async throws {
    let space = try makeSpace()
    let vault = try await makeVault(space)
    let principal = Principal(actor: .publicReader, group: .shared)
    let stream = try await space.observeFS(glob: "**", from: Rev(0), group: vault, as: principal)
    var events = stream.makeAsyncIterator()
    #expect(await events.next() != nil)

    try await space.removeGrant(.group, GroupID.shared.rawValue, in: vault, by: (try await space.ensureDevPerson()).actor, acting: vault)
    #expect(await events.next() == nil)
  }

  @Test(.timeLimit(.minutes(1))) func aClosedStreamsWatchEndsInsideItsThrottle() async throws {
    let clock = VirtualClock()
    let regions = RegionDouble()
    let space = try makeSpace(clock: clock, regions: regions.source)
    let table = try await makeTable(space)
    let sql = "SELECT n FROM \"/t.table\""
    let cancelled = Collector<Void>()
    let cancellations = Task { for await _ in regions.cancelled { await cancelled.append(()) } }
    defer { cancellations.cancel() }

    let first = Collector<Rows>()
    let firstStream = try space.observeRows(sql, throttle: .seconds(10), as: .shared(.publicReader))
    let firstConsumer = Task { do { for try await rows in firstStream { await first.append(rows) } } catch {} }
    _ = try await awaitItems(first, atLeast: 1)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    // The watch is in its throttle when its socket closes: the close alone ends the watch and its region.
    try await clock.sleeping(where: { $0 == .seconds(10) })
    firstConsumer.cancel()
    await firstConsumer.value

    _ = try await awaitItems(cancelled, atLeast: 1, timeout: .seconds(5))
    #expect(regions.cancellations == 1)
    #expect(regions.starts == 1)
  }

  @Test(.timeLimit(.minutes(1))) func aRegionFailureClosesTheStream() async throws {
    let regions = RegionDouble()
    let space = try makeSpace(regions: regions.source)
    _ = try await makeTable(space)
    let stream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .zero, as: .shared(.publicReader))
    var frames = 0
    for try await _ in stream {
      frames += 1
      if frames == 1 { regions.fail() }
    }
    #expect(frames == 1)
  }

  @Test(.timeLimit(.minutes(1))) func aBurstOfChangedSnapshotsIsNeverSleptThrough() async throws {
    let space = try makeSpace()
    let table = try await makeTable(space)
    let sql = "SELECT n FROM \"/t.table\""
    let streams = 24
    var collectors: [Collector<Rows>] = []
    var consumers: [Task<Void, Never>] = []
    defer { consumers.forEach { $0.cancel() } }
    for _ in 0 ..< streams {
      let snapshots = Collector<Rows>()
      collectors.append(snapshots)
      let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
      consumers.append(Task { do { for try await rows in stream { await snapshots.append(rows) } } catch {} })
    }
    for snapshots in collectors { _ = try await awaitItems(snapshots, atLeast: 1, timeout: .seconds(10)) }

    // Every write wakes every watch at once, so a result published while the lane looks for one must not be slept through.
    for n in 1 ... 30 {
      _ = try await space.mutateRows(table, [.insert([.integer(n), .string("x")])], in: .shared, acting: .shared)
      for snapshots in collectors { _ = try await awaitItems(snapshots, atLeast: n + 1, timeout: .seconds(10)) }
    }
  }

  @Test(.timeLimit(.minutes(1))) func aBurstOfAttachesIsNeverLostWhileTheWatchersLoopTurns() async throws {
    let space = try makeSpace()
    _ = try await makeTable(space)
    let sql = "SELECT n FROM \"/t.table\""
    let streams = 200
    var collectors: [Collector<Rows>] = []
    var consumers: [Task<Void, Never>] = []
    defer { consumers.forEach { $0.cancel() } }

    // Each attach registers a watch the long effect must start, however busy it is looking for one.
    for _ in 0 ..< streams {
      let snapshots = Collector<Rows>()
      collectors.append(snapshots)
      let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
      consumers.append(Task { do { for try await rows in stream { await snapshots.append(rows) } } catch {} })
    }
    for snapshots in collectors { _ = try await awaitItems(snapshots, atLeast: 1, timeout: .seconds(20)) }
  }

  /// Closing marks the runtime first, under the lock that hands the worker out: an attach from then on is refused, not given a worker nobody would stop.
  @Test(.timeLimit(.minutes(1))) func aClosingSpaceMakesNoWorkerForAnObservation() async throws {
    let folder = try ScratchFolder("observation-closing")
    let file = folder.url.appending(path: "space.sqlite")
    let gate = StatementGate(sql: "expires_at = 0")
    let space = try Space.open(file: file)
    try gate.install(on: space.database)
    let sql = "SELECT 1 AS one"
    let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    var frames = stream.makeAsyncIterator()
    #expect(try await frames.next()?.rows == [[.integer(1)]])
    defer { gate.release() }

    // The close is held at the release of the leases: the last moment a worker could still be made.
    gate.arm()
    let closing = Task { try await space.close() }
    await gate.reached()
    #expect(throws: ObservationsUnavailable.self) {
      _ = try space.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    }
    gate.release()
    try await closing.value

    // And the job is free for the next process on the file.
    let next = try Space.open(file: file)
    let again = try next.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    var after = again.makeAsyncIterator()
    #expect(try await after.next()?.rows == [[.integer(1)]])
    try await next.close()
  }

  /// A roll leaves two servers on one file: the other process's commit never reaches the writer's hooks, so the watch wakes on the writer's `data_version` alone.
  @Test(.timeLimit(.minutes(1))) func aCommitFromAnotherWriterWakesTheWatch() async throws {
    let folder = try ScratchFolder("observation-foreign-commit")
    let file = folder.url.appending(path: "space.sqlite")
    let clock = VirtualClock()
    let space = try withDependencies { $0.continuousClock = clock } operation: { try Space.open(file: file) }
    let other = try WuweiDatabase(path: file.path)
    let table = try await makeTable(space)
    _ = try await space.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)

    let snapshots = Collector<Rows>()
    let stream = try space.observeRows("SELECT n FROM \"/t.table\" ORDER BY n", throttle: .zero, as: .shared(.publicReader))
    let consumer = Task { do { for try await rows in stream { await snapshots.append(rows) } } catch {} }
    defer { consumer.cancel() }
    #expect(try await awaitItems(snapshots, atLeast: 1).first?.rows == [[.integer(1)]])

    try other.write { handle in
      try MigrationDB(handle: handle).execute(sql: "INSERT INTO \"shared:/t.table\" (\"n\", \"s\") VALUES (2, 'b')")
    }
    // No local write follows: only the clock moving wakes the watch.
    try await clock.sleeping(where: { $0 == .seconds(1) })
    await clock.advance(by: .seconds(1))
    #expect(try await awaitItems(snapshots, atLeast: 2).last?.rows == [[.integer(1)], [.integer(2)]])

    try other.closeWriter()
    try await space.close()
  }

  @Test(.timeLimit(.minutes(1))) func aRevocationAfterAPageCeilingCannotLeakLaterCommits() async throws {
    let folder = try ScratchFolder("observation-revocation")
    let file = folder.url.appending(path: "space.sqlite")
    let gate = StatementGate(sql: "")
    let space = try Space(database: try WuweiDatabase(path: file.path), fileReads: { worker in
      let live = FileWatchReads(worker: worker)
      return FileWatchReads(read: { opening, after in
        let page = try live.page(opening, after: after)
        gate.block()
        return page
      })
    })
    defer { gate.release() }
    let vault = try await makeVault(space)
    let principal = Principal(actor: .publicReader, group: .shared)
    let stream = try await space.observeFS(glob: "**", from: Rev(0), group: vault, as: principal)
    var caughtUp = stream.makeAsyncIterator()
    #expect(await caughtUp.next() != nil)

    gate.arm()
    _ = try await space.fs(vault).write("/watched.md", bytes("w"), ifMatch: nil)
    await gate.reached()
    let revoking = Task { try await space.removeGrant(.group, GroupID.shared.rawValue, in: vault, by: (try await space.ensureDevPerson()).actor, acting: vault) }
    gate.release()
    try await revoking.value
    _ = try await space.fs(vault).write("/leaked.md", bytes("leak"), ifMatch: nil)
    // A local write wakes the watch, which now reads the planted revocation and ends: nothing written after it is news to the reader.
    _ = try await space.fs(vault).write("/marker.md", bytes("m"), ifMatch: nil)
    var leaked: [String] = []
    while let commit = await caughtUp.next() { leaked += commit.events.map(\.path) }
    #expect(!leaked.contains("/leaked.md"))
  }

  /// A stream closed before the rollover stays gone: the next worker's job greets no socket for it, and a stream attached after the rollover starts exactly one watch.
  @Test(.timeLimit(.minutes(2))) func aClosedStreamsWatchStaysGoneAcrossARollover() async throws {
    let folder = try ScratchFolder("observation-rollover-closed")
    let file = folder.url.appending(path: "space.sqlite")
    let regions = RegionDouble()
    let old = try Space(database: try WuweiDatabase(path: file.path), regions: regions.source)
    let table = try await makeTable(old)
    _ = try await old.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    let cancelled = Collector<Void>()
    let cancellations = Task { for await _ in regions.cancelled { await cancelled.append(()) } }
    defer { cancellations.cancel() }

    let sql = "SELECT n FROM \"/t.table\""
    let first = Collector<Rows>()
    let firstStream = try old.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    let firstConsumer = Task { do { for try await rows in firstStream { await first.append(rows) } } catch {} }
    _ = try await awaitItems(first, atLeast: 1)
    #expect(regions.starts == 1)

    firstConsumer.cancel()
    await firstConsumer.value
    _ = try await awaitItems(cancelled, atLeast: 1, timeout: .seconds(5))
    #expect(regions.cancellations == 1)

    await old.stopWorker()
    let new = try Space(database: try WuweiDatabase(path: file.path), regions: regions.source)
    #expect(regions.starts == 1)

    let again = try new.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    var rows = again.makeAsyncIterator()
    #expect(try await rows.next()?.rows == [[.integer(1)]])
    #expect(regions.starts == 2)
    try await new.close()
    try await old.close()
  }

  @Test func aRolloverCarriesTheStreamsWithTheJob() async throws {
    let folder = try ScratchFolder("observation-rollover")
    let file = folder.url.appending(path: "space.sqlite")
    let old = try Space.open(file: file)
    let table = try await makeTable(old)
    _ = try await old.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    let sql = "SELECT n FROM \"/t.table\" ORDER BY n"

    let rows = try old.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    var snapshots = rows.makeAsyncIterator()
    #expect(try await snapshots.next()?.rows == [[.integer(1)]])
    let files = try await old.observeFS(glob: "**", group: .shared, as: .shared(.publicReader))
    var commits = files.makeAsyncIterator()

    let new = try Space.open(file: file)
    await #expect(throws: ObservationsUnavailable.self) {
      _ = try await new.observeFS(glob: "**", group: .shared, as: .shared(.publicReader))
    }
    #expect(throws: ObservationsUnavailable.self) {
      _ = try new.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    }

    await old.stopWorker()
    #expect(try await snapshots.next() == nil)
    #expect(await commits.next() == nil)

    let again = try new.observeRows(sql, throttle: .zero, as: .shared(.publicReader))
    var after = again.makeAsyncIterator()
    #expect(try await after.next()?.rows == [[.integer(1)]])
    let commitsAgain = try await new.observeFS(glob: "**", group: .shared, as: .shared(.publicReader))
    var arriving = commitsAgain.makeAsyncIterator()

    _ = try await new.mutateRows(table, [.insert([.integer(2), .string("b")])], in: .shared, acting: .shared)
    #expect(try await after.next()?.rows == [[.integer(1)], [.integer(2)]])
    let commit = try #require(await arriving.next() as FSCommit?)
    #expect(commit.group == .shared)
    #expect(commit.events.map(\.path) == ["/t.table"])
    try await new.close()
    try await old.close()
  }
}

/// A group `shared` may read, holding one file.
private func makeVault(_ space: Space) async throws -> GroupID {
  let owner = try await space.ensureDevPerson()
  let vault = try await space.createGroup(alias: "vault", owner: owner.account)
  try await space.setVisibility(.private, of: vault, by: (try await space.ensureDevPerson()).actor, acting: vault)
  try await space.setGrant(.group, GroupID.shared.rawValue, role: .read, in: vault, by: (try await space.ensureDevPerson()).actor, acting: vault)
  _ = try await space.fs(vault).write("/readme.md", bytes("# Vault\n"), ifMatch: nil)
  return vault
}

/// The region observations a test watches the job start and end, and the handle to fail one the way an observation that errors does.
private final class RegionDouble: Sendable {
  private struct State {
    var starts = 0
    var cancellations = 0
    var failing: [@Sendable () -> Void] = []
  }

  private let state = Mutex(State())
  private let cancelledStream: AsyncStream<Void>
  private let cancelledEvents: AsyncStream<Void>.Continuation

  init() {
    let (stream, events) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(64))
    cancelledStream = stream
    cancelledEvents = events
  }

  var starts: Int { state.withLock { $0.starts } }
  var cancellations: Int { state.withLock { $0.cancellations } }
  var cancelled: AsyncStream<Void> { cancelledStream }

  var source: (@Sendable (@escaping RegionSource) -> RegionSource) {
    { subscribe in
      return { tables, wakes in
        self.state.withLock {
          $0.starts += 1
          $0.failing.append { wakes.finish() }
        }
        let cancel = subscribe(tables, wakes)
        return {
          self.state.withLock { $0.cancellations += 1 }
          self.cancelledEvents.yield(())
          cancel()
        }
      }
    }
  }

  /// Ends every region observation, as one that errors does.
  func fail() {
    for failing in state.withLock({ $0.failing }) { failing() }
  }
}

private final class StatementGate: Sendable {
  let sql: String

  private struct State {
    var armed = false
    var reached: AsyncStream<Void>.Continuation?
    var blocked = DispatchSemaphore(value: 0)
  }

  private let state = Mutex(State())
  private let reachedStream: AsyncStream<Void>
  private let reachedEvents: AsyncStream<Void>.Continuation

  init(sql: String) {
    self.sql = sql
    let (stream, events) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    reachedStream = stream
    reachedEvents = events
    state.withLock { $0.reached = reachedEvents }
  }

  func arm() { state.withLock { $0.armed = true } }

  func install(on database: WuweiDatabase) throws {
    try database.accessWriter(label: "test.writer") { handle in
      let context = Unmanaged.passRetained(self).toOpaque()
      let code = sqlite3_set_clientdata(handle, "test.statement-gate", context) { Unmanaged<StatementGate>.fromOpaque($0!).release() }
      precondition(code == SQLITE_OK)
      sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
        let gate = Unmanaged<StatementGate>.fromOpaque(context!).takeUnretainedValue()
        let sql = String(cString: sqlite3_sql(OpaquePointer(statement!))!)
        if sql.contains(gate.sql) { gate.block() }
        return 0
      }, context)
    }
  }

  func block() {
    let block = state.withLock { state -> Bool in
      guard state.armed else { return false }
      state.armed = false
      return true
    }
    guard block else { return }
    _ = state.withLock { $0.reached?.yield(()) }
    state.withLock { $0.blocked }.wait()
  }

  func reached() async {
    var events = reachedStream.makeAsyncIterator()
    _ = await events.next()
  }

  func release() { _ = state.withLock { $0.blocked.signal() } }
}
