import Dispatch
import GRDBSQLite
import SpaceSQL
import Synchronization

final class FixtureWriter: Sendable {
  private let handle: Mutex<OpaquePointer>
  private let queue = DispatchQueue(label: "fixture-writer")

  init(path: String) throws {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
    guard let handle else { preconditionFailure("SQLite did not allocate a fixture connection") }
    guard code == SQLITE_OK else {
      let failure = SQLiteFailure(code: code, message: String(cString: sqlite3_errmsg(handle)))
      sqlite3_close_v2(handle)
      throw failure
    }
    sqlite3_busy_timeout(handle, 5000)
    self.handle = Mutex(handle)
  }

  deinit {
    _ = handle.withLock { sqlite3_close_v2($0) }
  }

  func write(_ sql: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        do {
          try self.execute(sql)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func execute(_ sql: String) throws {
    try handle.withLock { handle in
      let code = sqlite3_exec(handle, sql, nil, nil, nil)
      guard code == SQLITE_OK else {
        throw SQLiteFailure(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
      }
    }
  }
}
