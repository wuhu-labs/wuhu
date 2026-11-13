import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import MainHub
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Synchronization
import Testing
import Wuwei
import struct Wuwei.Database
import WuweiQueries

private let url = URL(string: "https://events.example/stream")!
private let observation = SubscriptionID("obs.delivery")

@Cell private struct StreamReceiver {
  static let schema = ["CREATE TABLE stream_receipts (\(ownerColumn), event TEXT NOT NULL)"]

  mutating func streamed(_ batch: StreamBatch) throws {
    try db.execute(StreamReceipt.insert { StreamReceipt(event: batch.event!.id ?? "") })
  }

  mutating func mirrored(_ event: String) throws {
    try db.execute(StreamReceipt.insert { StreamReceipt(event: event) })
  }

  mutating func ack(_ job: StreamJob.ID) {
    ctx.send(.acked, to: job)
  }
}

@Table("stream_receipts") private struct StreamReceipt: Owned {
  let event: String
}

private struct StreamCommit: Sendable, Equatable {
  let cursor: String
  let pending: String?
  let deliveries: Int
  let receipts: Int
  let acks: Int
}

private final class StreamCommits: TransactionObserver, Sendable {
  let values = Mutex<[StreamCommit]>([])
  let job: String
  let receiver: String

  init(job: StreamJob.ID, receiver: StreamReceiver.ID) {
    self.job = job.description
    self.receiver = receiver.description
  }

  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: GRDB.Database) {}
  func databaseDidCommit(_ db: GRDB.Database) {
    do {
      guard let row = try Row.fetchOne(db, sql: """
      SELECT last_event_id, pending_event_id,
        (SELECT count(*) FROM wuwei_mail WHERE recipient = ?) AS deliveries,
        (SELECT count(*) FROM stream_receipts) AS receipts,
        (SELECT count(*) FROM wuwei_mail WHERE recipient = ?) AS acks
      FROM streams
      """, arguments: [receiver, job]) else { return }
      let value = StreamCommit(
        cursor: row["last_event_id"], pending: row["pending_event_id"],
        deliveries: row["deliveries"], receipts: row["receipts"], acks: row["acks"],
      )
      values.withLock { if $0.last != value { $0.append(value) } }
    } catch { Issue.record(error) }
  }
}

private func deliveryWorker(
  _ space: Space, _ events: EventServer,
  handler: @escaping @Sendable (HandlerJob.Params) async throws -> ScriptHandlerResult = { _ in throw UnexpectedCall("handler") },
) {
  var config = makeConfig()
  config.sources = events.sources
  space.worker.provide(withEscapedDependencies { dependencies in
    LoopClient(
      space: space, scripts: Scripts(), tools: ToolExecutor(main: MainConnection(), credential: { _ in throw MainUnavailable() }),
      store: space.sessions, config: config, sleep: { _ in { throw UnexpectedCall("sleep") } },
      dependencies: dependencies, scheduler: space.worker.scheduler,
      handler: handler,
    )
  })
  space.worker.register(.cell(StreamReceiver.self))
  registerSessionCells(in: space)
  space.worker.register(.job(HandlerJob.self))
}

enum DeliveryCut: CaseIterable { case mailed, taken, acked }

@Suite struct StreamDeliveryTests {
  @Test(arguments: DeliveryCut.allCases, [false, true]) func `one outstanding delivery survives every mail and ack cut`(cut: DeliveryCut, noID: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("stream-delivery-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let events = EventServer()
      let firstID = noID ? "" : "1"
      deliveryWorker(old, events)
      deliveryWorker(new, events)
      let job = StreamJob.ID("delivery")
      let receiver = StreamReceiver.ID("receiver")
      _ = try await new.worker.call(receiver) { _ in true }
      let commits = StreamCommits(job: job, receiver: receiver)
      await old.writer.add(transactionObserver: commits)
      await new.writer.add(transactionObserver: commits)
      old.worker.start()
      try old.worker.create(job, params: .init(dialer: .group(.shared), session: nil, subscription: observation, url: url, throttle: 1, owner: receiver.recipient.retyped()))
      try await until("first dial") { events.dials.count == 1 }
      events.send((noID ? "" : "id: 1\n") + "data: one\n\nid: 2\ndata: two\n\n", on: 0)
      try await until("send and pending commit together before receiver takes mail") {
        commits.values.withLock { $0.contains { $0.pending == firstID && $0.deliveries == 1 && $0.receipts == 0 } }
      }
      if cut == .mailed { await old.stopWorker() }
      new.worker.start()
      await time.advance(by: 2)
      try await until("the receiver takes only one event") { new.worker.cell(receiver).db.rows(StreamReceipt.all).count == 1 }
      try await holds("the second event cannot replace the outstanding one") {
        new.worker.cell(receiver).db.rows(StreamReceipt.all).map(\.event) == [firstID]
          && new.worker.job(job).db.rows(StreamRow.all).first?.pendingEventID == firstID
      }
      if cut != .mailed {
        await old.worker.quiesce()
        if cut == .acked {
          try await new.worker.call(receiver) { $0.ack(job) }
          #expect(new.worker.hasMail(for: job.recipient))
        }
        await old.stopWorker()
        await time.advance(by: 2)
      }
      if cut != .acked {
        try await holds("replacement waits for the existing delivery instead of dialling") { events.dials.count == 1 }
        try await new.worker.call(receiver) { $0.ack(job) }
      }
      try await until("replacement consumes the outstanding ack before dialling") { events.dials.count == 2 }
      #expect(events.dials[1].lastEventID == (noID ? nil : "1"))
      events.send("id: 2\ndata: two\n\n", on: 1)
      try await until("only the next event is delivered") { new.worker.cell(receiver).db.rows(StreamReceipt.all).map(\.event) == [firstID, "2"] }
      try await new.worker.call(receiver) { $0.ack(job) }
      try await until("the next ack advances the cursor") { new.worker.job(job).db.rows(StreamRow.all).first?.lastEventID == "2" }
      let values = commits.values.withLock { $0 }
      #expect(values.contains { $0.pending == firstID && $0.acks == 1 && $0.cursor == "" })
      #expect(values.contains { $0.pending == nil && $0.acks == 0 && $0.cursor == firstID })
      for value in values {
        if value.pending == firstID { #expect(value.deliveries + value.receipts == 1, "\(value)") }
        if value.deliveries > 0 { #expect(value.pending != nil) }
        if value.pending == nil { #expect(value.acks == 0) }
        if value.acks > 0 { #expect(value.pending != nil) }
        #expect(value.deliveries <= 1)
      }
      for (before, after) in zip(values, values.dropFirst()) where before.acks > 0 && after.acks == 0 {
        #expect(after.pending == nil)
        #expect(after.cursor == before.pending)
      }
      #expect(values.filter { $0.cursor == "2" }.allSatisfy { $0.pending == nil && $0.acks == 0 })
      await new.stopWorker()
      try await old.close()
      try await new.close()
    }
  }
}

extension StreamDeliveryTests {
  @Test func `a firing sent but not acked finishes once across two workers`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("stream-handler-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let seeding = SessionExecution(space: old, loopConfig: makeConfig())
      let session = try await old.sessions.createSession(group: .shared, title: "stream", kind: .agent, createdBy: "owner", model: .test)
      await seeding.shutdown()
      let events = EventServer()
      let fired = Box<[String]>([])
      let gate = Latch()
      let cancelling = Box(false)
      let handler: @Sendable (HandlerJob.Params) async throws -> ScriptHandlerResult = { params in
        let data = params.input.object!["event"]!.object!["data"]!.stringValue!
        fired.withLock { $0.append(data) }
        if data == "one" {
          await withTaskCancellationHandler {
            await gate.wait()
          } onCancel: { cancelling.withLock { $0 = true } }
        }
        return .init(wakes: [])
      }
      deliveryWorker(old, events, handler: handler)
      deliveryWorker(new, events, handler: handler)
      let cell = ObserverCell.ID(.session(session), observation)
      let job = StreamJob.ID(cell.key)
      old.worker.start()
      try await old.worker.call(cell) {
        try $0.arm(Arming(.init(id: observation, kind: .stream(url: url, throttleSeconds: 1), handler: "/record.js")))
      }
      try await until("first dial") { events.dials.count == 1 }
      events.send("id: 1\ndata: one\n\nid: 2\ndata: two\n\n", on: 0)
      try await until("the first handler holds the event") { fired.value == ["one"] }
      #expect(old.worker.job(job).db.rows(StreamRow.all).first?.pendingEventID == "1")
      new.worker.start()
      try await holds("the new worker cannot start another firing while old holds it") { fired.value == ["one"] }
      let drain = Task { await old.stopWorker() }
      try await until("the old worker drains the held firing") { cancelling.value }
      gate.release()
      await drain.value
      await time.advance(by: 2)
      try await until("the replacement consumes the completion and dials after one") { events.dials.count == 2 }
      #expect(events.dials[1].lastEventID == "1")
      events.send("id: 2\ndata: two\n\n", on: 1)
      try await until("the next event fires exactly once") { new.worker.job(job).db.rows(StreamRow.all).first?.lastEventID == "2" }
      #expect(fired.value == ["one", "two"])
      let firings = new.worker.cell(cell).db.rows(FiringRow.all.order { _ in #sql("rowid", as: Int64.self) }.select { $0.outcome })
      #expect(firings == ["ok", "ok"])
      await new.stopWorker()
      try await old.close()
      try await new.close()
    }
  }
}

@Job private struct MirrorDeliveryJob {
  typealias Params = StreamReceiver.ID
  typealias Message = Never
  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    let row = StreamRow(sessionID: nil, subscriptionID: observation.rawValue, url: url.absoluteString, armedAt: "", pendingEventID: "mirror")
    try db.execute(StreamRow.insert { row })
    ctx.send(ctx.params).mirrored("mirror")
    return .done
  }
}

extension StreamDeliveryTests {
  @Test func `a row written before its send shares the commit and survives a drain once`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("write-send-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let events = EventServer()
      deliveryWorker(old, events)
      deliveryWorker(new, events)
      old.worker.register(.job(MirrorDeliveryJob.self))
      new.worker.register(.job(MirrorDeliveryJob.self))
      let receiver = StreamReceiver.ID("mirror-receiver")
      let job = MirrorDeliveryJob.ID("mirror")
      _ = try await new.worker.call(receiver) { _ in true }
      let commits = StreamCommits(job: StreamJob.ID(job.key), receiver: receiver)
      await old.writer.add(transactionObserver: commits)
      await new.writer.add(transactionObserver: commits)
      try old.worker.create(job, params: receiver)
      try await until("write and following mail share a commit") {
        commits.values.withLock { $0.contains { $0.pending == "mirror" && $0.deliveries == 1 } }
      }
      await old.stopWorker()
      new.worker.start()
      await time.advance(by: 2)
      try await until("replacement takes the mail once") { new.worker.cell(receiver).db.rows(StreamReceipt.all).map(\.event) == ["mirror"] }
      let snapshots = commits.values.withLock { $0 }
      #expect(snapshots.allSatisfy { $0.pending != "mirror" || $0.deliveries + $0.receipts == 1 })
      await new.stopWorker()
      try await old.close()
      try await new.close()
    }
  }
}
