import ControlledTime
import DeterministicDependencies
import Dispatch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import Scratch
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Synchronization
import Testing
import Wuwei

private final class ObservationMarkerCommits: TransactionObserver, Sendable {
  let first = Mutex<[String: Int]>([:])

  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: GRDB.Database) {}
  func databaseDidCommit(_ db: GRDB.Database) {
    do {
      let rows = try GRDB.Row.fetchAll(db, sql: """
      SELECT marker, (SELECT count(*) FROM wuwei_mail WHERE recipient = ?) AS deliveries
      FROM observation_slots WHERE marker IS NOT NULL
      """, arguments: [ObservationProbe.ID("probe").description])
      for row in rows {
        let marker: String = row["marker"]
        let deliveries: Int = row["deliveries"]
        first.withLock { if $0[marker] == nil { $0[marker] = deliveries } }
      }
    } catch { Issue.record(error) }
  }
}

@Suite(.deterministicDependencies(clock: VirtualClock())) struct ObservationSlotTests {
  private func probe(_ space: Space, _ output: AsyncStream<ObservationReply>.Continuation) {
    space.worker.register(.cell(ObservationProbe.self))
    space.worker.provide(ObservationProbeOutput(send: { output.yield($0) }))
    space.worker.start()
  }

  private func watch(_ sql: String, id: String = "test", marker: String? = nil) -> ObservationWatch {
    ObservationWatch(
      slot: ObservationSlot(owner: .group(.shared), subscription: SubscriptionID(id), incarnation: UUID()),
      statement: sql, principal: .observer(group: .shared, name: "test"),
      recipient: ObservationProbe.ID("probe").recipient.retyped(), marker: marker,
    )
  }

  private func rows(_ reply: ObservationReply?, slot: ObservationSlot) throws -> Rows {
    guard case let .observed(observed, rows, marker) = reply else { throw MissingReply() }
    #expect(observed == slot)
    #expect(marker == rowsMarker(rows))
    return rows
  }

  private func table(_ space: Space) async throws -> SpacePath {
    let path = try SpacePath(validating: "/slot.table")
    _ = try await space.createTable(path, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
    return path
  }

  @Test func replacementRetiresTheRunAndItsQueuedAndLateResults() async throws {
    let state = ObservationJob.State()
    let watching = watch("SELECT 1 AS n")
    let id = ObservationJob.WatchID.slot(watching.slot.key)
    state.register(id, .slot(watching))
    let running = state.watching()
    let old = try #require(running.first)
    _ = try #require(state.listening(old))
    state.publish(old, .rows(Rows(columns: ["n"], decltypes: [nil], rows: [[.integer(1)]])))
    state.publish(old, .failed("old failure"))
    state.remove(id)
    state.register(id, .slot(watching))
    #expect(state.takeResults().isEmpty)
    #expect(state.watching().subtracting(running).count == 1)
    state.publish(old, .rows(Rows(columns: ["n"], decltypes: [nil], rows: [[.integer(1)]])))
    state.publish(old, .failed("late old failure"))
    #expect(state.takeResults().isEmpty)
  }

  @Test func replacingAHeldQueryWithTheSameSlotMailsOnlyTheReplacement() async throws {
    let folder = try ScratchFolder("observation-replacement")
    let gate = SlotReadGate()
    let writer = try DatabaseQueue(path: folder.url.appending(path: "space.sqlite").path, configuration: Space.makeConfiguration())
    let space = try Space(writer: writer, trace: { gate.trace($0) })
    defer { gate.release() }
    let (stream, output) = AsyncStream<ObservationReply>.makeStream()
    probe(space, output)
    var replies = stream.makeAsyncIterator()
    let old = watch("SELECT 1 AS n")
    space.worker.send(.watch(old), to: ObservationJob.address)
    await gate.reached()
    space.worker.send(.unwatch(old.slot), to: ObservationJob.address)
    let replacement = ObservationWatch(slot: old.slot, statement: "SELECT 2 AS n", principal: old.principal, recipient: old.recipient, marker: nil)
    space.worker.send(.watch(replacement), to: ObservationJob.address)
    let barrier = watch("SELECT 3 AS n", id: "barrier")
    space.worker.send(.watch(barrier), to: ObservationJob.address)
    var replaced = false
    while true {
      let reply = await replies.next()
      guard case let .observed(slot, _, _) = reply else { throw MissingReply() }
      if slot == barrier.slot { break }
      #expect(try rows(reply, slot: replacement.slot).rows == [[.integer(2)]])
      #expect(!replaced)
      replaced = true
    }
    gate.release()
    if !replaced { #expect(try rows(await replies.next(), slot: replacement.slot).rows == [[.integer(2)]]) }
    let after = watch("SELECT 4 AS n", id: "after")
    space.worker.send(.watch(after), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: after.slot).rows == [[.integer(4)]])
    try await space.close()
  }

  @Test func duplicateArmKeepsTheStandingRowsMarker() async throws {
    let space = try makeSpace()
    let (stream, output) = AsyncStream<ObservationReply>.makeStream()
    probe(space, output)
    var replies = stream.makeAsyncIterator()
    let watching = watch("SELECT 1 AS n")
    space.worker.send(.watch(watching), to: ObservationJob.address)
    let first = try rows(await replies.next(), slot: watching.slot)
    space.worker.send(.watch(watching), to: ObservationJob.address)
    let barrier = watch("SELECT 3 AS n", id: "barrier")
    space.worker.send(.watch(barrier), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: barrier.slot).rows == [[.integer(3)]])
    let marker = try await space.writer.read { db in
      try String.fetchOne(db, sql: "SELECT marker FROM observation_slots WHERE slot = ?", arguments: [watching.slot.key])
    }
    #expect(marker == rowsMarker(first))
    try await space.close()
  }

  @Test func armChangesCancelAndFailedStatementAreMail() async throws {
    let space = try makeSpace()
    let table = try await table(space)
    let (stream, output) = AsyncStream<ObservationReply>.makeStream()
    probe(space, output)
    var replies = stream.makeAsyncIterator()
    let watching = watch("SELECT n FROM \"/slot.table\" ORDER BY n")
    space.worker.send(.watch(watching), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: watching.slot).rows.isEmpty)
    _ = try await space.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)
    #expect(try rows(await replies.next(), slot: watching.slot).rows == [[.integer(1)]])

    space.worker.send(.unwatch(watching.slot), to: ObservationJob.address)
    let broken = watch("SELECT n FROM \"/absent.table\"", id: "failed")
    space.worker.send(.watch(broken), to: ObservationJob.address)
    guard case let .failed(slot, reason) = await replies.next() else { throw MissingReply() }
    #expect(slot == broken.slot)
    #expect(reason.contains("absent"))
    #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM observation_slots WHERE slot = ?", arguments: [watching.slot.key]) } == 0)
    _ = try await space.mutateRows(table, [.insert([.integer(2)])], in: .shared, acting: .shared)
    let barrier = watch("SELECT 3 AS n", id: "barrier")
    space.worker.send(.watch(barrier), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: barrier.slot).rows == [[.integer(3)]])
    try await space.close()
  }

  @Test func rolloverRerunsDurableSlotsSilentlyThenMailsOneChange() async throws {
    let folder = try ScratchFolder("observation-slot-rollover")
    let file = folder.url.appending(path: "space.sqlite")
    let old = try Space.open(file: file)
    let table = try await table(old)
    let commits = ObservationMarkerCommits()
    let (stream, output) = AsyncStream<ObservationReply>.makeStream()
    probe(old, output)
    await old.writer.add(transactionObserver: commits)
    var replies = stream.makeAsyncIterator()
    let watching = watch("SELECT n FROM \"/slot.table\" ORDER BY n")
    old.worker.send(.watch(watching), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: watching.slot).rows.isEmpty)

    let new = try Space.open(file: file)
    probe(new, output)
    await new.writer.add(transactionObserver: commits)
    await old.stopWorker()
    new.worker.poke(ObservationJob.address.recipient)
    _ = try await new.mutateRows(table, [.insert([.integer(1)])], in: .shared, acting: .shared)
    #expect(try rows(await replies.next(), slot: watching.slot).rows == [[.integer(1)]])
    let barrier = watch("SELECT 3 AS n", id: "barrier")
    new.worker.send(.watch(barrier), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: barrier.slot).rows == [[.integer(3)]])
    let deliveries = commits.first.withLock { $0 }
    #expect(deliveries.count == 3)
    #expect(deliveries.values.allSatisfy { $0 == 1 })
    try await new.close()
    try await old.close()
  }

  @Test func revocationEndsSocketAndFailsSlotWithoutAnotherSnapshot() async throws {
    let space = try makeSpace()
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('vault', '2026-01-01')")
    }
    let vault = GroupID(rawValue: "vault")
    try await space.setGrant(.group, "shared", role: .read, in: vault, by: .anonymous, acting: .shared)
    _ = try await space.fs(vault).write("/secret.md", Data("secret".utf8), ifMatch: nil)
    let sql = "SELECT path FROM \"wuhu://vault.localspace/docs\""
    let socket = try space.observeRows(sql, throttle: .zero, as: .shared(.anonymous))
    var snapshots = socket.makeAsyncIterator()
    #expect(try await snapshots.next()?.rows == [[.text("/secret.md")]])
    let (stream, output) = AsyncStream<ObservationReply>.makeStream()
    probe(space, output)
    var replies = stream.makeAsyncIterator()
    let watching = watch(sql)
    space.worker.send(.watch(watching), to: ObservationJob.address)
    #expect(try rows(await replies.next(), slot: watching.slot).rows == [[.text("/secret.md")]])
    try await space.removeGrant(.group, "shared", in: vault, by: .anonymous, acting: .shared)
    #expect(try await snapshots.next() == nil)
    guard case let .failed(slot, _) = await replies.next() else { throw MissingReply() }
    #expect(slot == watching.slot)
    try await space.close()
  }
}

private struct MissingReply: Error {}

private final class SlotReadGate: Sendable {
  private let armed = Mutex(true)
  private let blocked = DispatchSemaphore(value: 0)
  private let events = AsyncStream<Void>.makeStream()

  func trace(_ sql: String) {
    guard sql == "SELECT 1 AS n", armed.withLock({ armed in
      defer { armed = false }
      return armed
    }) else { return }
    events.continuation.yield(())
    blocked.wait()
  }

  func reached() async {
    var arrivals = events.stream.makeAsyncIterator()
    _ = await arrivals.next()
  }

  func release() { blocked.signal() }
}
