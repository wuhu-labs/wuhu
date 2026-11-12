import Synchronization
import Testing
@testable import Wuwei

@Job private struct UndecodableJob {
  struct Params: Codable {
    let hydrate: Bool
  }

  typealias Message = Never

  static func hydrate(ctx: inout JobContext<Self>) throws {
    if ctx.params.hydrate { _ = try decode(Int.self, from: Array("\"bad state\"".utf8)) }
  }

  mutating func start() async throws -> Outcome { .hibernate }
}

@Cell private struct BootCreator {
  static let schema = ["CREATE TABLE boot_lost (\(ownerColumn), address TEXT NOT NULL)"]

  mutating func spawn(_ key: String, hydrate: Bool) {
    ctx.create(UndecodableJob.ID(key), params: .init(hydrate: hydrate))
  }

  mutating func lost(_ job: String) throws {
    try db.execute("INSERT INTO boot_lost (address) VALUES (?)", .text(job))
  }

  func losses() -> [String] {
    db.rows("SELECT address FROM boot_lost WHERE owner = cell()").map { $0[0].text! }
  }
}

@Job private struct BootParent {
  static let schema = ["CREATE TABLE parent_lost (\(ownerColumn), address TEXT NOT NULL)"]
  typealias Params = String
  enum Message: Codable { case unused }

  mutating func start() async throws -> Outcome {
    ctx.create(UndecodableJob.ID(ctx.params), params: .init(hydrate: true))
    _ = try await ctx.receive(within: .seconds(60))
    return .hibernate
  }

  func lost(_ job: String) throws {
    var context = ctx
    try context.db.execute("INSERT INTO parent_lost (address) VALUES (?)", .text(job))
  }

  func losses() -> [String] {
    db.rows("SELECT address FROM parent_lost WHERE owner = cell()").map { $0[0].text! }
  }
}

@Job private struct NonReceivingParent {
  static let schema = ["CREATE TABLE nonreceiving_parent (\(ownerColumn), event TEXT NOT NULL)"]
  struct Params: Codable {
    let child: String
    let hibernate: Bool
  }

  typealias Message = Never

  mutating func start() async throws -> Outcome {
    try db.execute("INSERT INTO nonreceiving_parent (event) VALUES ('started')")
    ctx.create(UndecodableJob.ID(ctx.params.child), params: .init(hydrate: true))
    if !ctx.params.hibernate {
      let valve = ctx.dependency(Valve.self)
      try await ctx.effect { try await valve.wait("parent") }
    }
    return .hibernate
  }

  func lost(_ job: String) throws {
    var context = ctx
    try context.db.execute("INSERT INTO nonreceiving_parent (event) VALUES (?)", .text(job))
  }

  func events() -> [String] {
    db.rows("SELECT event FROM nonreceiving_parent WHERE owner = cell()").map { $0[0].text! }
  }
}

private final class BootProbe: Sendable {
  let creates = Mutex(0)
  let hydrates = Mutex(0)
}

@Job private struct RetryBoot {
  enum Params: String, Codable { case createDecode, hydrateTransient }
  enum Temporary: Error { case unavailable }
  typealias Message = Never

  static func create(ctx: inout JobContext<Self>) throws {
    ctx.dependency(BootProbe.self).creates.withLock { $0 += 1 }
    if ctx.params == .createDecode { _ = try decode(Int.self, from: Array("null".utf8)) }
  }

  static func hydrate(ctx: inout JobContext<Self>) throws {
    ctx.dependency(BootProbe.self).hydrates.withLock { $0 += 1 }
    throw Temporary.unavailable
  }

  mutating func start() async throws -> Outcome { .done }
}

@Suite struct LostJobTests {
  @Test(arguments: [false, true], [RetryBoot.Params.createDecode, .hydrateTransient])
  fileprivate func otherBootFailuresKeepTheirRetryPolicy(shared: Bool, params: RetryBoot.Params) throws {
    let world = World(shared: shared)
    let probe = BootProbe()
    var dependencies = Dependencies()
    dependencies.register(probe)
    let a = try world.node("a", [.job(RetryBoot.self)], dependencies: dependencies)
    try a.worker.create(RetryBoot.ID("retry"), params: params)
    world.run(for: .seconds(15))
    #expect(probe.creates.withLock { $0 } >= (params == .createDecode ? 2 : 1))
    #expect(probe.hydrates.withLock { $0 } >= (params == .createDecode ? 0 : 2))
    #expect(try a.worker.store.read { try $0.rows("SELECT phase FROM wuwei_job").first?[0].text } == (params == .createDecode ? "new" : "live"))
    #expect(try a.worker.store.read { try $0.rows("SELECT id FROM wuwei_mail").isEmpty })
  }

  @Test(arguments: [false, true], [false, true])
  func aBootDecodeFailureEndsAndDurablyNotifiesItsCreatorOnce(shared: Bool, hydrate: Bool) throws {
    let world = World(shared: shared)
    let a = try world.node("creator", [.cell(BootCreator.self)])
    let creator = BootCreator.ID("creator")
    let child = UndecodableJob.ID("child")
    a.worker.send(creator).spawn(child.key, hydrate: hydrate)
    world.run(for: .seconds(1))
    if !hydrate {
      try a.worker.store.write {
        try $0.execute("UPDATE wuwei_job SET params = ?", .blob(Array("{}".utf8)))
      }
    }
    world.simulation.kill(a.process)

    let b = try world.node("jobs", [.job(UndecodableJob.self)])
    let closed = Mutex(0)
    _ = try #require(b.worker.attach(Feed.self, to: child, opening: 0) { output in
      if case .closed = output { closed.withLock { $0 += 1 } }
    })
    world.run(for: .seconds(15))
    #expect(closed.withLock { $0 } == 1)
    let jobs = try b.worker.store.read { try $0.rows("SELECT address, phase, creator FROM wuwei_job ORDER BY address") }
    #expect(jobs.map { $0["phase"].text! } == ["done"])
    #expect(jobs.map { $0["creator"].text } == [creator.description])
    let mail = try b.worker.store.read { try $0.rows("SELECT recipient, lifecycle, payload FROM wuwei_mail") }
    #expect(mail.count == 1)
    #expect(mail.first?["recipient"].text == creator.description)
    #expect(mail.first?["lifecycle"].text == "lost")
    #expect(try mail.first.map { try decode(String.self, from: $0["payload"].blob!) } == child.description)
    let fences = try b.worker.store.read { try $0.rows("SELECT fence FROM wuwei_addressable ORDER BY address").map { $0[0].integer! } }
    world.run(for: .seconds(30))
    #expect(try b.worker.store.read { try $0.rows("SELECT fence FROM wuwei_addressable ORDER BY address").map { $0[0].integer! } } == fences)

    let c = try world.node("receiver", [.cell(BootCreator.self)])
    world.run(for: .seconds(15))
    #expect(c.worker.cell(creator).losses() == [child.description])
    world.run(for: .seconds(30))
    #expect(c.worker.cell(creator).losses() == [child.description])
    #expect(!c.worker.hasMail(for: creator.recipient))
  }

  @Test(arguments: [false, true])
  func aJobCreatorReceivesLifecycleMailOutsideItsMessageType(shared: Bool) throws {
    let world = World(shared: shared)
    let a = try world.node("a", [.job(BootParent.self), .job(UndecodableJob.self)])
    let parent = BootParent.ID("parent")
    let child = UndecodableJob.ID("child")
    try a.worker.create(parent, params: child.key)
    world.run(for: .seconds(15))
    #expect(a.worker.job(parent).losses() == [child.description])
    world.run(for: .seconds(30))
    #expect(a.worker.job(parent).losses() == [child.description])
  }

  @Test(arguments: [false, true], [false, true])
  func aNeverMessageParentTakesLossAtBootOrWhileParkedWithoutReceiving(shared: Bool, hibernate: Bool) throws {
    let world = World(shared: shared)
    let valve = Valve()
    var dependencies = Dependencies()
    dependencies.register(valve)
    let a = try world.node("a", [.job(NonReceivingParent.self), .job(UndecodableJob.self)], dependencies: dependencies)
    let parent = NonReceivingParent.ID("parent")
    let child = UndecodableJob.ID("child")
    try a.worker.create(parent, params: .init(child: child.key, hibernate: hibernate))
    world.run(for: .seconds(15))
    #expect(a.worker.job(parent).events().filter { $0 == child.description } == [child.description])
    #expect(!a.worker.hasMail(for: parent.recipient))
    #expect(a.worker.job(parent).events().filter { $0 == "started" }.count == (hibernate ? 2 : 1))
    valve.open("parent")
    world.run(for: .seconds(1))
    let events = a.worker.job(parent).events()
    world.run(for: .seconds(30))
    #expect(a.worker.job(parent).events() == events)
  }

  @Test(arguments: [false, true], [false, true])
  func anUnownedBootDecodeFailureKeepsRetrying(shared: Bool, hydrate: Bool) throws {
    let world = World(shared: shared)
    let outside = try world.node("outside", [])
    let job = UndecodableJob.ID("unowned")
    try outside.worker.create(job, params: .init(hydrate: hydrate))
    if !hydrate {
      try outside.worker.store.write { try $0.execute("UPDATE wuwei_job SET params = ?", .blob(Array("{}".utf8))) }
    }
    let a = try world.node("jobs", [.job(UndecodableJob.self)])
    world.run(for: .seconds(15))
    #expect(try a.worker.store.read { try $0.rows("SELECT phase FROM wuwei_job").first?[0].text } == (hydrate ? "live" : "new"))
    #expect(!a.worker.hasMail(for: job.recipient))
    let fence = try a.worker.store.read { try $0.rows("SELECT fence FROM wuwei_addressable").first![0].integer! }
    world.run(for: .seconds(15))
    #expect(try a.worker.store.read { try $0.rows("SELECT fence FROM wuwei_addressable").first![0].integer! } > fence)
  }

  @Test func openingAnOldOuterFileAddsNullableColumnsWithoutChangingMailOrJobs() throws {
    let world = World()
    let file = try FileDatabase(path: world.path, synchronous: false)
    try file.write { handle, _ in
      let db = Connection(borrowing: handle)
      try db.execute("ALTER TABLE wuwei_job DROP COLUMN creator")
      try db.execute("ALTER TABLE wuwei_mail DROP COLUMN lifecycle")
      try db.execute("INSERT INTO wuwei_job (address, params) VALUES ('old/job', ?)", .blob(Array("{}".utf8)))
      try db.execute("INSERT INTO wuwei_mail (recipient, payload) VALUES ('old/cell', ?)", .blob(Array("{}".utf8)))
    }
    let upgraded = try FileDatabase(path: world.path, synchronous: false)
    try upgraded.read { handle in
      let db = Connection(borrowing: handle)
      let job = try db.rows("SELECT creator FROM wuwei_job").first
      let mail = try db.rows("SELECT lifecycle, payload FROM wuwei_mail").first
      #expect(job?[0] == .null)
      #expect(mail?[0] == .null)
      #expect(mail?[1].blob == Array("{}".utf8))
    }
    _ = try FileDatabase(path: world.path, synchronous: false)
  }
}
