import ControlledTime
import DeterministicDependencies
import Dispatch
import Foundation
import GRDB
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
    let stream = try space.observeRows("SELECT n FROM \"/t.table\" ORDER BY n", throttle: .zero, as: .shared(.anonymous))
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
    let slowStream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .seconds(10), as: .shared(.anonymous))
    let slowConsumer = Task { do { for try await rows in slowStream { await slow.append(rows) } } catch {} }
    defer { slowConsumer.cancel() }
    let fast = Collector<Rows>()
    let fastStream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .zero, as: .shared(.anonymous))
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
    let stream = try space.observeRows("SELECT rev FROM revisions", throttle: .zero, as: .shared(.anonymous))
    var frames = 0
    for try await _ in stream { frames += 1 }
    #expect(frames == 0)
  }

  @Test func aFileStreamEndsWhenTheReaderLosesTheGroup() async throws {
    let space = try makeSpace()
    let vault = try await makeVault(space)
    let principal = Principal(actor: .anonymous, group: .shared)
    let stream = try await space.observeFS(glob: "**", from: Rev(0), group: vault, as: principal)
    var events = stream.makeAsyncIterator()
    #expect(await events.next() != nil)

    try await space.removeGrant(.group, GroupID.shared.rawValue, in: vault, by: .anonymous, acting: vault)
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
    let firstStream = try space.observeRows(sql, throttle: .seconds(10), as: .shared(.anonymous))
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
    let stream = try space.observeRows("SELECT n FROM \"/t.table\"", throttle: .zero, as: .shared(.anonymous))
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
      let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
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
      let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
      consumers.append(Task { do { for try await rows in stream { await snapshots.append(rows) } } catch {} })
    }
    for snapshots in collectors { _ = try await awaitItems(snapshots, atLeast: 1, timeout: .seconds(20)) }
  }

  /// Closing marks the runtime first, under the lock that hands the worker out: an attach from then on is refused, not given a worker nobody would stop.
  @Test(.timeLimit(.minutes(1))) func aClosingSpaceMakesNoWorkerForAnObservation() async throws {
    let folder = try ScratchFolder("observation-closing")
    let file = folder.url.appending(path: "space.sqlite")
    let gate = StatementGate(sql: "expires_at = 0")
    var configuration = Space.makeConfiguration()
    configuration.prepareDatabase { db in db.trace(options: .statement) { gate.trace($0) } }
    let space = try Space(writer: try DatabaseQueue(path: file.path, configuration: configuration))
    let sql = "SELECT 1 AS one"
    let stream = try space.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    var frames = stream.makeAsyncIterator()
    #expect(try await frames.next()?.rows == [[.integer(1)]])
    defer { gate.release() }

    // The close is held at the release of the leases: the last moment a worker could still be made.
    gate.arm()
    let closing = Task { try await space.close() }
    await gate.reached()
    #expect(throws: ObservationsUnavailable.self) {
      _ = try space.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    }
    gate.release()
    try await closing.value

    // And the job is free for the next process on the file.
    let next = try Space.open(file: file)
    let again = try next.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    var after = again.makeAsyncIterator()
    #expect(try await after.next()?.rows == [[.integer(1)]])
    try await next.close()
  }

  /// The journal read is gated at its statement: the one point between a watch's access read and its journal read, which one database read makes none.
  @Test(.timeLimit(.minutes(1))) func aRevocationBetweenTheAccessCheckAndTheJournalCannotLeakACommit() async throws {
    let folder = try ScratchFolder("observation-revocation")
    let file = folder.url.appending(path: "space.sqlite")
    let gate = StatementGate(sql: "FROM fs_versions")
    var configuration = Space.makeConfiguration()
    configuration.prepareDatabase { db in db.trace(options: .statement) { gate.trace($0) } }
    let space = try Space(writer: try DatabasePool(path: file.path, configuration: configuration))
    defer { gate.release() }
    let vault = try await makeVault(space)
    let principal = Principal(actor: .anonymous, group: .shared)
    let stream = try await space.observeFS(glob: "**", from: Rev(0), group: vault, as: principal)
    var caughtUp = stream.makeAsyncIterator()
    #expect(await caughtUp.next() != nil)

    gate.arm()
    _ = try await space.fs(vault).write("/watched.md", bytes("w"), ifMatch: nil)
    await gate.reached()
    // Between the two reads: the reader loses the group, and a file is written that it may no longer see.
    try await space.removeGrant(.group, GroupID.shared.rawValue, in: vault, by: .anonymous, acting: vault)
    _ = try await space.fs(vault).write("/leaked.md", bytes("leak"), ifMatch: nil)
    gate.release()
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
    let old = try Space(writer: try DatabaseQueue(path: file.path, configuration: Space.makeConfiguration()), regions: regions.source)
    let table = try await makeTable(old)
    _ = try await old.mutateRows(table, [.insert([.integer(1), .string("a")])], in: .shared, acting: .shared)
    let cancelled = Collector<Void>()
    let cancellations = Task { for await _ in regions.cancelled { await cancelled.append(()) } }
    defer { cancellations.cancel() }

    let sql = "SELECT n FROM \"/t.table\""
    let first = Collector<Rows>()
    let firstStream = try old.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    let firstConsumer = Task { do { for try await rows in firstStream { await first.append(rows) } } catch {} }
    _ = try await awaitItems(first, atLeast: 1)
    #expect(regions.starts == 1)

    firstConsumer.cancel()
    await firstConsumer.value
    _ = try await awaitItems(cancelled, atLeast: 1, timeout: .seconds(5))
    #expect(regions.cancellations == 1)

    await old.stopWorker()
    let new = try Space(writer: try DatabaseQueue(path: file.path, configuration: Space.makeConfiguration()), regions: regions.source)
    #expect(regions.starts == 1)

    let again = try new.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
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

    let rows = try old.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    var snapshots = rows.makeAsyncIterator()
    #expect(try await snapshots.next()?.rows == [[.integer(1)]])
    let files = try await old.observeFS(glob: "**", group: .shared, as: .shared(.anonymous))
    var commits = files.makeAsyncIterator()

    let new = try Space.open(file: file)
    await #expect(throws: ObservationsUnavailable.self) {
      _ = try await new.observeFS(glob: "**", group: .shared, as: .shared(.anonymous))
    }
    #expect(throws: ObservationsUnavailable.self) {
      _ = try new.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    }

    await old.stopWorker()
    #expect(try await snapshots.next() == nil)
    #expect(await commits.next() == nil)

    let again = try new.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    var after = again.makeAsyncIterator()
    #expect(try await after.next()?.rows == [[.integer(1)]])
    let commitsAgain = try await new.observeFS(glob: "**", group: .shared, as: .shared(.anonymous))
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
  let vault = GroupID(rawValue: "vault")
  try await space.writer.write { db in
    try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('vault', '2026-01-01T00:00:00.000Z')")
  }
  try await space.setGrant(.group, GroupID.shared.rawValue, role: .read, in: vault, by: .anonymous, acting: vault)
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

  var source: (@Sendable (any DatabaseWriter) -> RegionSource) {
    { writer in
      let changes = ChangeSource()
      writer.add(transactionObserver: ChangeSourceFeeder(changes), extent: .databaseLifetime)
      return { tables, wakes in
        self.state.withLock {
          $0.starts += 1
          $0.failing.append { wakes.finish() }
        }
        let cancel = changes.subscribe(tables, wakes)
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

/// Blocks the first statement containing `sql` after `arm`, on the writer's own queue, until `release`.
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

  func trace(_ event: Database.TraceEvent) {
    guard case let .statement(statement) = event, statement.sql.contains(sql) else { return }
    let block = state.withLock { state -> Bool in
      guard state.armed else { return false }
      state.armed = false
      return true
    }
    guard block else { return }
    state.withLock { $0.reached?.yield(()) }
    state.withLock { $0.blocked }.wait()
  }

  func reached() async {
    var events = reachedStream.makeAsyncIterator()
    _ = await events.next()
  }

  func release() { state.withLock { $0.blocked.signal() } }
}
