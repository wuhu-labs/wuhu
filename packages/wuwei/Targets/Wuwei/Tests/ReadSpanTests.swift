import Dispatch
import Synchronization
import Testing
@testable import Wuwei

@Cell private struct SnapshotCell {
  static let schema = ["CREATE TABLE snapshot_value (\(ownerColumn), n INTEGER NOT NULL)"]

  func value() -> Int64 {
    db.one("SELECT n FROM snapshot_value WHERE owner = cell()")?.integer ?? 0
  }

  func cell(_ other: ID) -> SnapshotCell { ctx.cell(other) }
  func job(_ other: SnapshotJob.ID) -> SnapshotJob { ctx.job(other) }
  func nested(_ other: ID, depth: Int) -> Int64 {
    depth == 0 ? value() : ctx.cell(other).nested(id, depth: depth - 1)
  }

  mutating func set(_ n: Int64) throws {
    try db.execute("DELETE FROM snapshot_value WHERE owner = cell()")
    try db.execute("INSERT INTO snapshot_value (n) VALUES (?)", .integer(n))
  }

  mutating func setAndRead(_ n: Int64) throws -> Int64 {
    try set(n)
    let answer = ctx.cell(id).nested(id, depth: 3)
    #expect(db.one("SELECT cell()") == .text(id.key))
    return answer
  }
}

@Job private struct SnapshotJob {
  typealias Params = Int
  typealias Message = Never
  func cell(_ id: SnapshotCell.ID) -> SnapshotCell { ctx.cell(id) }
  mutating func start() async throws -> Outcome { .done }
}

private struct ChangeDuringRead: Sendable {
  let run: @Sendable () -> Void
}

@Job private struct ReadThenWriteJob {
  typealias Params = Int
  typealias Message = Never
  static let schema = ["CREATE TABLE read_then_write (\(ownerColumn), n INTEGER)"]

  mutating func start() async throws -> Outcome {
    let counter = Counter.ID("counter")
    #expect(db.one("SELECT count(*) FROM counter") == 1)
    let handle = ctx.cell(counter)
    #expect(handle.value() == 0)
    ctx.dependency(ChangeDuringRead.self).run()
    #expect(db.one("SELECT value FROM counter") == 0)
    #expect(handle.value() == 0)
    try db.execute("INSERT INTO read_then_write (n) VALUES (1)")
    #expect(handle.value() == 2)
    return .done
  }
}

private func onAnotherThread(_ body: @escaping @Sendable () -> Void) {
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    body()
    done.signal()
  }
  done.wait()
}

@Suite struct ReadSpanTests {
  @Test(arguments: [false, true])
  func aHandleIsLazyAndKeepsOneSnapshotAtEveryDepth(shared: Bool) throws {
    let world = World(shared: shared)
    let node = try world.node("span", [.cell(SnapshotCell.self), .job(SnapshotJob.self)])
    let a = SnapshotCell.ID("a")
    let b = SnapshotCell.ID("b")
    let worker = node.worker
    let simulation = world.simulation
    do {
      let root = worker.cell(a)
      let derived = root.job(SnapshotJob.ID("job")).cell(b).cell(a)
      worker.send(a).set(1)
      worker.send(b).set(10)
      world.run(for: .milliseconds(10))
      #expect(root.value() == 1)
      onAnotherThread {
        worker.send(a).set(2)
        worker.send(b).set(20)
        simulation.run(for: .milliseconds(10))
      }
      #expect(root.value() == 1)
      #expect(derived.value() == 1)
      #expect(root.cell(b).value() == 10)
      #expect(root.nested(b, depth: 4) == 1)
    }
    #expect(worker.cell(a).value() == 2)
    #expect(worker.cell(b).value() == 20)
  }

  @Test(arguments: [false, true])
  func anExplicitScopeSharesItsSnapshotAcrossRootsAndExistence(shared: Bool) throws {
    let world = World(shared: shared)
    let node = try world.node("span", [.cell(SnapshotCell.self), .job(SnapshotJob.self)])
    let a = SnapshotCell.ID("a")
    let b = SnapshotCell.ID("b")
    let job = SnapshotJob.ID("job")
    try node.worker.read { reader in
      #expect(reader.cell(a).value() == 0)
      #expect(!reader.exists(job))
      node.worker.send(b).set(20)
      try node.worker.create(job, params: 0)
      let simulation = world.simulation
      onAnotherThread { simulation.run(for: .milliseconds(10)) }
      #expect(reader.cell(b).value() == 0)
      #expect(!reader.exists(job))
    }
    #expect(node.worker.cell(b).value() == 20)
    #expect(node.worker.exists(job))
  }

  @Test(arguments: [false, true])
  func nestedStepHandlesSeeUncommittedWrites(shared: Bool) throws {
    let world = World(shared: shared)
    let node = try world.node("span", [.cell(SnapshotCell.self)])
    let answer = Mutex<Int64?>(nil)
    Task(executorPreference: node.process) {
      do {
        let value = try await node.worker.call(SnapshotCell.ID("a")) { try $0.setAndRead(7) }
        answer.withLock { $0 = value }
      } catch { Issue.record(error) }
    }
    world.run(for: .milliseconds(10))
    #expect(answer.withLock { $0 } == 7)
  }

  @Test func aReadOnlyStretchEndsItsSnapshotAtTheFirstWrite() throws {
    let world = World(shared: true)
    let file = try FileDatabase(path: world.path, synchronous: false)
    let node = try world.node("stretch", [.cell(Counter.self), .job(ReadThenWriteJob.self)], starts: false)
    node.worker.provide(ChangeDuringRead(run: {
      do {
        try file.write { handle in try Connection(borrowing: handle).execute("UPDATE counter SET value = 2") }
      } catch { Issue.record(error) }
    }))
    try node.worker.create(ReadThenWriteJob.ID("read"), params: 0)
    world.run(for: .milliseconds(10))
    #expect(node.worker.cell(Counter.ID("counter")).value() == 2)
  }

  @Test func aScopedHandleCannotEscapeItsScope() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      let world = World(shared: true)
      let node = try world.node("span", [.cell(SnapshotCell.self)])
      let escaped = node.worker.read { $0.cell(SnapshotCell.ID("escaped")) }
      _ = escaped.value()
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a read scope's handle outlived it"))
  }

  @Test(arguments: [false, true], [false, true])
  func aSpanCannotBeUsedOrReleasedOnAnotherThread(shared: Bool, release: Bool) async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) { [shared = shared as Bool, release = release as Bool] in
      let world = World(shared: shared)
      let node = try world.node("span", [.cell(SnapshotCell.self)])
      let handle = Mutex<SnapshotCell?>(node.worker.cell(SnapshotCell.ID("held")))
      handle.withLock { _ = $0!.value() }
      onAnotherThread {
        handle.withLock {
          if release { $0 = nil }
          else { _ = $0!.value() }
        }
      }
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a read span changed threads: a handle is being held across an await"))
  }

  @Test(arguments: [false, true])
  func aThrowClosesTheScopeEvenWhenAHandleEscaped(shared: Bool) async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) { [shared = shared as Bool] in
      enum Failure: Error { case expected }
      let world = World(shared: shared)
      let node = try world.node("span", [.cell(SnapshotCell.self)])
      var escaped: SnapshotCell?
      do {
        try node.worker.read { reader in
          escaped = reader.cell(SnapshotCell.ID("escaped"))
          _ = escaped!.value()
          throw Failure.expected
        }
      } catch Failure.expected {}
      #expect(node.worker.cell(SnapshotCell.ID("fresh")).value() == 0)
      _ = escaped!.value()
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a read scope's handle outlived it"))
  }

  @Test func aSpanCannotPrepareAKindAfterItsFirstStatement() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      let world = World(shared: true)
      let node = try world.node("span", [.cell(SnapshotCell.self)])
      node.worker.read { reader in
        _ = reader.cell(SnapshotCell.ID("a")).value()
        let worker = node.worker
        onAnotherThread { _ = worker.cell(Counter.ID("other")) }
        _ = reader.cell(Counter.ID("late")).value()
      }
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("read span reached unprepared kind Counter: register it before reading"))
  }

  @Test(arguments: [false, true], [0, 1, 2, 3])
  func independentReadsOnTheSameThreadTrap(shared: Bool, path: Int) async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) { [shared = shared as Bool, path = path as Int] in
      let world = World(shared: shared)
      let node = try world.node("span", [.cell(SnapshotCell.self), .job(SnapshotJob.self)])
      let first = node.worker.cell(SnapshotCell.ID("first"))
      let second = node.worker.cell(SnapshotCell.ID("second"))
      _ = first.value()
      switch path {
      case 0: _ = second.value()
      case 1: node.worker.read { _ in }
      case 2: _ = node.worker.exists(SnapshotJob.ID("job"))
      case 3: _ = node.worker.hasMail(for: SnapshotCell.ID("first").recipient)
      default: preconditionFailure()
      }
      _ = first.value()
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a second read span began while one is open on this thread: take both handles from one `worker.read`, or a handle is being held across an await"))
  }

  @Test func readersAreReusedWithoutBoundingActiveSpans() throws {
    let world = World(shared: true)
    _ = try FileDatabase(path: world.path, synchronous: false)
    let pool = SQLiteReaders(path: world.path, idleLimit: 1)
    let first = try pool.beginRead().access { UInt(bitPattern: $0) }
    let reused = try pool.beginRead().access { UInt(bitPattern: $0) }
    #expect(first == reused)
    let active = try (0 ..< 6).map { _ in try pool.beginRead() }
    let handles = active.map { $0.access { UInt(bitPattern: $0) } }
    #expect(Set(handles).count == 6)
  }
}
