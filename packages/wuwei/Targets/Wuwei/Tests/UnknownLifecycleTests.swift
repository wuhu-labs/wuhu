import Testing
@testable import Wuwei

@Job private struct LifecycleIdle {
  static let schema = ["CREATE TABLE lifecycle_starts (\(ownerColumn))"]
  typealias Params = Int
  typealias Message = Never

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO lifecycle_starts DEFAULT VALUES")
    return .hibernate
  }

  func starts() -> Int {
    db.rows("SELECT count(*) FROM lifecycle_starts WHERE owner = cell()")[0][0].integer.map(Int.init)!
  }
}

@Cell private struct LifecycleSink {
  mutating func unused() {}
}

@Suite struct UnknownLifecycleTests {
  @Test(arguments: [false, true])
  func anUnknownLifecycleIsConsumedForCellsAndJobs(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try world.node("a", [.job(LifecycleIdle.self), .cell(LifecycleSink.self)], starts: false)
    let job = LifecycleIdle.ID("idle")
    let cell = LifecycleSink.ID("sink")
    try a.worker.create(job, params: 0)
    try a.worker.store.write { db in
      for recipient in [job.description, cell.description] {
        try db.execute("INSERT INTO wuwei_mail (recipient, payload, lifecycle) VALUES (?, ?, 'future')", .text(recipient), .blob(Array("{}".utf8)))
      }
    }
    a.worker.start()
    world.run(for: .seconds(15))
    #expect(try a.worker.store.read { try $0.rows("SELECT id FROM wuwei_mail").isEmpty })
    let starts = a.worker.job(job).starts()
    #expect(starts >= 1)
    world.run(for: .seconds(30))
    #expect(a.worker.job(job).starts() == starts)
  }
}
