import GRDBSQLite

struct ReadTarget {
  let address: String
  let owner: String
  let schema: [String]

  init<Target: Addressable>(_ id: Target.ID) {
    address = id.description
    owner = id.key
    schema = Target.schema
  }
}

final class ReadSpan {
  let store: OuterStore
  private var transaction: (any SharedReadTransaction)?
  private var thread: UInt?
  private var copies: [String: Connection] = [:]
  private var prepared: Set<String> = []
  private var closed = false

  init(_ store: OuterStore) { self.store = store }

  func prepare<Target: Addressable>(_ type: Target.Type) {
    precondition(!closed, "a read scope's handle outlived it")
    if store.file != nil || prepared.contains(type.kind) { return }
    if transaction != nil {
      let applied = rows("SELECT applied FROM wuwei_schema WHERE kind = ?", [.text(type.kind)]).first?["applied"].integer
      precondition(applied == Int64(type.schema.count), "read span reached unprepared kind \(type.kind): register it before reading")
    } else {
      store.prepare(kind: type.kind, schema: type.schema, owned: type.owned)
    }
    prepared.insert(type.kind)
  }

  func close() {
    if let thread { Lane.preconditionReadThread(thread) }
    copies.removeAll()
    transaction = nil
    if let thread { Lane.endedRead(thread) }
    thread = nil
    closed = true
  }

  deinit { close() }

  private func reader() throws -> any SharedReadTransaction {
    precondition(!closed, "a read scope's handle outlived it")
    if let transaction {
      Lane.preconditionReadThread(thread!)
      return transaction
    }
    let thread = Lane.beganRead()
    do {
      let transaction = try store.database.beginRead()
      self.transaction = transaction
      self.thread = thread
      return transaction
    } catch {
      Lane.endedRead(thread)
      throw error
    }
  }

  func rows(_ sql: String, _ arguments: [Value], owner: String? = nil) -> [Row] {
    do {
      return try reader().access { handle in
        let db = Connection(borrowing: handle)
        let previous = db.owner
        db.owner = owner
        defer { db.owner = previous }
        return db.read(sql, arguments)
      }
    } catch { preconditionFailure("\(sql): \(error)") }
  }

  func read(_ target: ReadTarget, _ sql: String, _ arguments: [Value]) -> [Row] {
    precondition(!closed, "a read scope's handle outlived it")
    if store.file == nil { return rows(sql, arguments, owner: target.owner) }
    if let copy = copies[target.address] {
      Lane.preconditionReadThread(thread!)
      return copy.read(sql, arguments)
    }
    do {
      let transaction = try reader()
      let row = rows("SELECT id, page_count FROM wuwei_addressable WHERE address = ?", [.text(target.address)]).first
      let id = row?["id"].integer ?? 0
      let pages = PageFile(pageCount: UInt32(row?["page_count"].integer ?? 0), writable: true) { number in
        try transaction.access { try Connection(borrowing: $0).page(id, number) }
      }
      let db = try Connection(file: pages, owner: target.owner)
      migrate(db, target.schema)
      copies[target.address] = db
      return db.read(sql, arguments)
    } catch { preconditionFailure("could not read \(target.address): \(error)") }
  }
}

public struct Reader {
  let worker: Worker
  let span: ReadSpan

  public func cell<C: Cell>(_ id: C.ID) -> C {
    worker.cell(id, reading: .span(span))
  }

  public func job<J: Job>(_ id: J.ID) -> J {
    worker.job(id, reading: .span(span))
  }

  public func exists<J: Job>(_ id: J.ID) -> Bool {
    worker.exists(id, reading: .span(span))
  }
}

enum Reading {
  case span(ReadSpan)
  case within(Incarnation)

  func prepare<Target: Addressable>(_ type: Target.Type) {
    switch self {
    case let .span(span): span.prepare(type)
    case let .within(incarnation): incarnation.prepare(type)
    }
  }

  func read(_ target: ReadTarget, _ sql: String, _ arguments: [Value]) -> [Row] {
    switch self {
    case let .span(span): span.read(target, sql, arguments)
    case let .within(incarnation): incarnation.read(target, sql, arguments)
    }
  }

  func rows(_ sql: String, _ arguments: [Value]) -> [Row] {
    switch self {
    case let .span(span): span.rows(sql, arguments)
    case let .within(incarnation): incarnation.readOuter(sql, arguments)
    }
  }
}
