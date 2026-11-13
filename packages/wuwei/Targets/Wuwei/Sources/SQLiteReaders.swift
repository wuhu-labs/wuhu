import GRDBSQLite
import Synchronization

public final class SQLiteReaders: Sendable {
  private struct State {
    var idle: [ReaderConnection] = []
    var opened = 0
    var closed = false
  }

  private let state = Mutex(State())
  private let path: String
  private let pragmas: [String]
  private let profile: @Sendable (String, String, Double) -> Void
  private let idleLimit: Int

  public init(path: String, idleLimit: Int = 4, pragmas: [String] = [], profile: @escaping @Sendable (String, String, Double) -> Void = { _, _, _ in }) {
    precondition(idleLimit >= 0)
    self.path = path
    self.idleLimit = idleLimit
    self.pragmas = pragmas
    self.profile = profile
  }

  public func beginRead() throws -> any SharedReadTransaction {
    let (idle, index): (ReaderConnection?, Int) = state.withLock { state -> (ReaderConnection?, Int) in
      precondition(!state.closed, "the read pool is closed")
      if let idle = state.idle.popLast() { return (idle, state.opened) }
      state.opened += 1
      return (nil, state.opened)
    }
    let connection: ReaderConnection
    if let idle {
      connection = idle
    } else {
      let db = try Connection(path: path, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
      try Connection.prepare(db.handle)
      db.setBusyHandler()
      for pragma in pragmas { try db.execute(pragma) }
      db.trace { [profile] sql, milliseconds in profile("wuwei.reader.\(index)", sql, milliseconds) }
      connection = ReaderConnection(db)
    }
    try connection.db.withLock { try $0.execute("BEGIN DEFERRED") }
    return ReadTransaction(connection: connection, pool: self)
  }

  public func close() {
    state.withLock { state in
      state.closed = true
      state.idle.removeAll()
    }
  }

  fileprivate func recycle(_ connection: ReaderConnection) {
    state.withLock { state in
      if !state.closed, state.idle.count < idleLimit { state.idle.append(connection) }
    }
  }
}

private final class ReaderConnection: Sendable {
  let db: Mutex<Connection>
  init(_ db: sending Connection) { self.db = Mutex(db) }
}

private final class ReadTransaction: SharedReadTransaction {
  let connection: ReaderConnection
  let pool: SQLiteReaders

  init(connection: ReaderConnection, pool: SQLiteReaders) {
    self.connection = connection
    self.pool = pool
  }

  func access<T: Sendable>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
    try connection.db.withLock { try body($0.handle) }
  }

  deinit {
    do { try connection.db.withLock { try $0.execute("ROLLBACK") } }
    catch { preconditionFailure("could not release a read transaction: \(error)") }
    pool.recycle(connection)
  }
}
