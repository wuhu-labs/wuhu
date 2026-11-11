import Synchronization
import Testing
import Wuwei

/// Counts its own steps from `around`, after whatever call ran: a message, a wake, a rolled-back message. It refuses, after the call, a step that noted "veto".
@Cell
struct Journal {
  static let schema = ["CREATE TABLE entry (text TEXT NOT NULL)", "CREATE TABLE due (at INTEGER NOT NULL)"]

  func entries() -> [String] {
    db.rows("SELECT text FROM entry ORDER BY rowid").map { $0[0].text! }
  }

  func nextWake() -> Instant? {
    db.one("SELECT MIN(at) FROM due")!.integer.map(Instant.init(milliseconds:))
  }

  mutating func around(_ call: (inout Journal) throws -> Void) throws {
    try call(&self)
    if entries().last == "veto" { throw Refused() }
    try db.execute("INSERT INTO entry VALUES (?)", .text("step \(entries().count)"))
  }

  mutating func note(_ text: String, wakeAt: Instant?) throws {
    try db.execute("INSERT INTO entry VALUES (?)", .text(text))
    if let wakeAt { try db.execute("INSERT INTO due VALUES (?)", .integer(wakeAt.milliseconds)) }
    if text == "boom" { throw Refused() }
  }

  mutating func wake() throws {
    try db.execute("DELETE FROM due")
    try db.execute("INSERT INTO entry VALUES ('woke')")
  }
}

@Suite struct AroundTests {
  @Test func aroundWrapsEveryCallInItsStep() throws {
    let world = World()
    _ = try world.node("a", [.cell(Journal.self)])
    let client = try world.client()
    let journal = Journal.ID("j")
    client.send(journal).note("hello", wakeAt: world.simulation.now + .seconds(2))
    client.send(journal).note("boom", wakeAt: nil)
    world.run(for: .seconds(1))
    #expect(client.cell(journal).entries() == ["hello", "step 1"])
    world.run(for: .seconds(2))
    #expect(client.cell(journal).entries() == ["hello", "step 1", "woke", "step 3"])
  }

  @Test func aCallerHearsWhatAroundThrowsAfterItsCall() throws {
    let world = World()
    let a = try world.node("a", [.cell(Journal.self)])
    let journal = Journal.ID("j")
    let heard = Mutex<Result<Int, any Error>?>(nil)
    let worker = a.worker
    Task(executorPreference: a.process) {
      let answer: Result<Int, any Error>
      do { answer = .success(try await worker.call(journal) { try $0.note("veto", wakeAt: nil); return $0.entries().count }) } catch { answer = .failure(error) }
      heard.withLock { $0 = answer }
    }
    world.run(for: .seconds(1))
    #expect(throws: Refused.self) { try heard.withLock { $0 }?.get() }
    #expect(worker.cell(journal).entries() == [])
  }
}
