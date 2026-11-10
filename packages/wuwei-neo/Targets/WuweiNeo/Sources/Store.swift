import Synchronization

/// The outer tables every worker shares: leases, mail, job rows, and on the layered backend the pages of every addressable.
final class OuterStore: Sendable {
  let database: any SharedDatabase
  /// The layered backend's file; `nil` on the shared backend.
  let file: FileDatabase?
  private let prepared = Mutex<Set<String>>([])

  init(_ storage: Storage) {
    switch storage {
    case let .layered(file):
      database = file
      self.file = file
    case let .shared(database):
      self.database = database
      file = nil
    }
  }

  /// One write transaction, with `cell()` returning `owner`.
  func write<T>(owner: String? = nil, _ body: (Connection) throws -> T) throws -> T {
    var result: T?
    try database.write { handle, host in
      let db = Connection(borrowing: handle)
      db.host = host
      db.owner = owner
      defer { db.owner = nil }
      result = try body(db)
    }
    return result!
  }

  func read<T>(owner: String? = nil, _ body: (Connection) throws -> T) throws -> T {
    var result: T?
    try database.read { handle in
      let db = Connection(borrowing: handle)
      db.owner = owner
      defer { db.owner = nil }
      result = try body(db)
    }
    return result!
  }

  /// The key of page `number` of addressable `id`: one integer, so a page is a single b-tree point lookup with its blob in the row.
  static func key(_ id: Int64, _ number: UInt32) -> Int64 {
    id << 32 | Int64(number)
  }

  func page(_ id: Int64, _ number: UInt32) throws -> [UInt8]? {
    try read { try $0.page(id, number) }
  }

  /// Checks the epoch's fence, which renews the lease, and applies its outer writes.
  func commit(_ epoch: Epoch, on db: Connection, now: Instant, leaseDuration: Duration) throws {
    let released = epoch.writes.contains { if case .finished = $0 { true } else if case .released = $0 { true } else { false } }
    let held = try db.rows(
      "UPDATE wuwei_addressable SET expires_at = ?, page_count = ? WHERE id = ? AND fence = ? RETURNING id",
      .integer(released ? 0 : (now + leaseDuration).milliseconds), .integer(Int64(epoch.pageCount)), .integer(epoch.lease.id), .integer(epoch.lease.fence),
    )
    guard !held.isEmpty else { throw Evicted(address: epoch.address) }
    for write in epoch.writes {
      switch write {
      case let .send(envelope):
        try db.execute("INSERT INTO wuwei_mail (recipient, payload) VALUES (?, ?)", .text(envelope.recipient), .blob(envelope.payload))
      case let .consume(mail):
        try db.execute("DELETE FROM wuwei_mail WHERE id = ?", .integer(mail))
      case let .create(job, params):
        try db.execute("INSERT INTO wuwei_job (address, params) VALUES (?, ?) ON CONFLICT DO NOTHING", .text(job), .blob(params))
      case .created:
        try db.execute("UPDATE wuwei_job SET phase = 'live' WHERE address = ?", .text(epoch.address))
      case .finished:
        try db.execute("UPDATE wuwei_job SET phase = 'done', wake_at = NULL WHERE address = ?", .text(epoch.address))
        try db.execute("DELETE FROM wuwei_mail WHERE recipient = ?", .text(epoch.address))
      case let .hibernated(until):
        try db.execute("UPDATE wuwei_job SET wake_at = ? WHERE address = ?", until.map { .integer($0.milliseconds) } ?? .null, .text(epoch.address))
      case let .wakes(at):
        try db.execute("UPDATE wuwei_addressable SET wake_at = ? WHERE id = ?", at.map { .integer($0.milliseconds) } ?? .null, .integer(epoch.lease.id))
      case .released:
        break
      }
    }
  }

  /// Brings a kind's tables in the shared database up to its schema, each statement once, tracked in `wuwei_schema`. Two kinds creating one table is a bug, and traps here.
  func prepare(kind: String, schema: [String]) {
    guard prepared.withLock({ $0.insert(kind).inserted }) else { return }
    do {
      try write { db in
        let applied = Int(try db.rows("SELECT applied FROM wuwei_schema WHERE kind = ?", .text(kind)).first?["applied"].integer ?? 0)
        precondition(applied <= schema.count, "lost schema steps of \(kind): \(applied) applied, \(schema.count) declared")
        for statement in schema[applied...] {
          try db.execute(statement)
        }
        try db.execute(
          "INSERT INTO wuwei_schema (kind, applied) VALUES (?, ?) ON CONFLICT (kind) DO UPDATE SET applied = excluded.applied",
          .text(kind), .integer(Int64(schema.count)),
        )
        try guardOwnedTables(db)
      }
    } catch {
      preconditionFailure("could not apply the schema of \(kind): \(error)")
    }
  }

  /// On the writer, a row of a table with an ``Addressable/ownerColumn`` may be written only by its owner: anything else aborts the statement.
  private func guardOwnedTables(_ db: Connection) throws {
    let tables = try db.rows(
      """
      SELECT m.name FROM sqlite_master AS m, pragma_table_info(m.name) AS c
      WHERE m.type = 'table' AND c.name = 'owner' AND c.dflt_value = 'cell()'
      """,
    )
    for table in tables.map({ $0["name"].text! }) {
      let quoted = table.replacing("\"", with: "\"\"")
      let checks = ["INSERT": "NEW.owner IS NOT cell()", "UPDATE": "NEW.owner IS NOT cell() OR OLD.owner IS NOT cell()", "DELETE": "OLD.owner IS NOT cell()"]
      for (operation, check) in checks {
        try db.execute(
          """
          CREATE TEMP TRIGGER IF NOT EXISTS "wuwei_guard_\(operation)_\(quoted)" BEFORE \(operation) ON main."\(quoted)"
          WHEN \(check) BEGIN SELECT RAISE(ABORT, 'a row of \(table.replacing("'", with: "''")) belongs to another addressable'); END
          """,
        )
      }
    }
  }
}

extension Connection {
  func page(_ id: Int64, _ number: UInt32) throws -> [UInt8]? {
    try rows("SELECT data FROM wuwei_pages WHERE key = ?", .integer(OuterStore.key(id, number))).first?["data"].blob
  }
}

struct Lease: Hashable, Sendable {
  let id: Int64
  let fence: Int64
}

struct Envelope: Hashable, Sendable {
  let recipient: String
  let payload: [UInt8]
}

struct Mail: Sendable {
  let id: Int64
  let payload: [UInt8]
}

/// An outer write that commits with an epoch.
enum Write: Sendable {
  case send(Envelope)
  case consume(mail: Int64)
  case create(job: String, params: [UInt8])
  case created
  case finished
  case hibernated(until: Instant?)
  /// A cell's `nextWake()`.
  case wakes(at: Instant?)
  case released
}

/// Everything one addressable wrote in one step of the shared backend, or sealed at one drain of the layered one.
struct Epoch: Sendable {
  let address: String
  let lease: Lease
  let number: UInt64
  let pages: [UInt32: [UInt8]]
  let pageCount: UInt32
  let writes: [Write]
}

/// The incarnation is gone: its lease was taken, or one of its epochs failed to commit. What it held back never went out.
public struct Evicted: Error {
  public let address: String
}

/// The layered backend's single writer of epochs. Whatever is sealed while a batch is being written becomes the next batch, in one outer transaction: no timer, and no wait when idle.
final class Shipper: Sendable {
  typealias Settle = @Sendable (Result<Void, any Error>) -> Void

  private struct Queue {
    var waiting: [(epoch: Epoch, settle: Settle)] = []
    var busy = false
    var lost: Set<Lease> = []
  }

  private let queue = Mutex(Queue())
  private let store: OuterStore
  private let scheduler: any Scheduler
  private let leaseDuration: Duration

  init(store: OuterStore, scheduler: any Scheduler, leaseDuration: Duration) {
    self.store = store
    self.scheduler = scheduler
    self.leaseDuration = leaseDuration
  }

  func ship(_ epoch: Epoch, _ settle: @escaping Settle) {
    let start = queue.withLock { queue in
      queue.waiting.append((epoch, settle))
      defer { queue.busy = true }
      return !queue.busy
    }
    if start { scheduler.post { self.writeNextBatch() } }
  }

  private func writeNextBatch() {
    let (batch, lost) = queue.withLock { queue in
      defer { queue.waiting = [] }
      queue.busy = !queue.waiting.isEmpty
      return (queue.waiting, queue.lost)
    }
    guard !batch.isEmpty else { return }
    let results = write(batch.map(\.epoch), lost: lost)
    queue.withLock { queue in
      for (item, result) in zip(batch, results) where (try? result.get()) == nil {
        queue.lost.insert(item.epoch.lease)
      }
    }
    for (item, result) in zip(batch, results) {
      item.settle(result)
    }
    scheduler.post { self.writeNextBatch() }
  }

  /// One savepoint per epoch, so a failing addressable doesn't sink the rest; after one of a lease's epochs fails, none of its later ones may land.
  private func write(_ batch: [Epoch], lost: Set<Lease>) -> [Result<Void, any Error>] {
    do {
      return try store.write { db in
        var lost = lost
        return batch.map { epoch -> Result<Void, any Error> in
          guard !lost.contains(epoch.lease) else { return .failure(Evicted(address: epoch.address)) }
          let result = Result { try db.transaction { try apply(epoch, to: db) } }
          if case .failure = result { lost.insert(epoch.lease) }
          return result
        }
      }
    } catch {
      return batch.map { _ in .failure(error) }
    }
  }

  private func apply(_ epoch: Epoch, to db: Connection) throws {
    try store.commit(epoch, on: db, now: scheduler.now, leaseDuration: leaseDuration)
    let id = epoch.lease.id
    for (number, data) in epoch.pages where number <= epoch.pageCount {
      try db.execute("INSERT OR REPLACE INTO wuwei_pages (key, data) VALUES (?, ?)", .integer(OuterStore.key(id, number)), .blob(data))
    }
    try db.execute("DELETE FROM wuwei_pages WHERE key > ? AND key <= ?", .integer(OuterStore.key(id, epoch.pageCount)), .integer(OuterStore.key(id, .max)))
  }
}
