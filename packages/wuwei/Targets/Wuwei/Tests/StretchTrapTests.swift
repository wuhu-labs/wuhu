import Testing
@testable import Wuwei

private enum OutsidePath: Sendable { case send, prepare, isStarted, start }

private struct OutsideWrite: Sendable {
  let run: @Sendable () -> Void
}

@Job private struct OutsidePathJob {
  typealias Params = Int
  typealias Message = Never
  static let schema = ["CREATE TABLE outside_step (\(ownerColumn), n INTEGER)"]

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO outside_step (n) VALUES (1)")
    ctx.dependency(OutsideWrite.self).run()
    return .done
  }
}

private func runOutsidePath(_ path: OutsidePath) throws {
  let world = World(shared: true)
  let node = try world.node("trap", [.job(OutsidePathJob.self)], starts: false)
  let worker = node.worker
  worker.provide(OutsideWrite(run: {
    switch path {
    case .send: worker.send(Ledger.ID("outside")).add(1)
    case .prepare: _ = worker.cell(Ledger.ID("unregistered")).total()
    case .isStarted: _ = worker.isStarted
    case .start: worker.start()
    }
  }))
  try worker.create(OutsidePathJob.ID("job"), params: 0)
  world.run(for: .milliseconds(10))
}

@Suite struct StretchTrapTests {
  @Test func anOutsideSendInsideAStretchTraps() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsidePath(.send)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot acquire the writer through an outside path: this thread already holds the writer"))
  }

  @Test func anOutsideReadHandlePreparationInsideAStretchTraps() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsidePath(.prepare)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot acquire the writer through an outside path: this thread already holds the writer"))
  }
}

@Job private struct JoinedStepJob {
  typealias Params = Bool
  typealias Message = Never
  static let schema = ["CREATE TABLE joined_step (\(ownerColumn), n INTEGER)"]

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO joined_step (n) VALUES (1)")
    let incarnation = db.access.incarnation
    if ctx.params {
      try incarnation.step { try incarnation.step {} }
    } else {
      do {
        try incarnation.step {
          try incarnation.write("INSERT INTO joined_step (n) VALUES (2)", []).get()
          throw Refused()
        }
      } catch is Refused {}
      try incarnation.step { try incarnation.write("INSERT INTO joined_step (n) VALUES (3)", []).get() }
    }
    return .done
  }
}

extension StretchTrapTests {
  @Test func joinedStepsDoNotNest() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      let world = World(shared: true)
      let node = try world.node("trap", [.job(JoinedStepJob.self)], starts: false)
      try node.worker.create(JoinedStepJob.ID("job"), params: true)
      world.run(for: .milliseconds(10))
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("steps do not nest"))
  }

  @Test func aThrowingJoinedStepRollsBackAndAllowsTheNextStep() throws {
    let world = World(shared: true)
    let node = try world.node("joined", [.job(JoinedStepJob.self)], starts: false)
    let job = JoinedStepJob.ID("job")
    try node.worker.create(job, params: false)
    world.run(for: .milliseconds(10))
    #expect(node.worker.job(job).db.rows("SELECT n FROM joined_step ORDER BY n").map { $0[0].integer! } == [1, 3])
  }
}

extension StretchTrapTests {
  @Test func aLifecycleReadInsideAStretchTrapsBeforeTakingTheLock() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsidePath(.isStarted)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot enter a writer-waiting lifecycle lock"))
  }

  @Test func startingTheWorkerInsideAStretchTrapsBeforeTakingTheLock() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsidePath(.start)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot enter a writer-waiting lifecycle lock"))
  }
}

@Cell private struct OutsidePathCell {
  mutating func outside() { ctx.dependency(OutsideWrite.self).run() }
}

private func runOutsideCall(_ path: OutsidePath) throws {
  let world = World(shared: true)
  let node = try world.node("call-trap", [.cell(OutsidePathCell.self)], starts: false)
  let worker = node.worker
  worker.provide(OutsideWrite(run: {
    switch path {
    case .send: worker.send(Ledger.ID("outside")).add(1)
    case .prepare: _ = worker.cell(Ledger.ID("unregistered")).total()
    case .isStarted: _ = worker.isStarted
    case .start: worker.start()
    }
  }))
  worker.task { try! await worker.call(OutsidePathCell.ID("cell")) { $0.outside() } }
  world.run(for: .milliseconds(10))
}

extension StretchTrapTests {
  @Test func anOutsideSendInsideACallTraps() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsideCall(.send)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot acquire the writer through an outside path"))
  }

  @Test func anOutsideReadHandlePreparationInsideACallTraps() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsideCall(.prepare)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot acquire the writer through an outside path"))
  }

  @Test func aLifecycleReadInsideACallTrapsBeforeTakingTheLock() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      try runOutsideCall(.isStarted)
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("a thread holding the writer cannot enter a writer-waiting lifecycle lock"))
  }
}
