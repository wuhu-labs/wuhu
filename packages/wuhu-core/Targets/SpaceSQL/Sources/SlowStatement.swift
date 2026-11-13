import GRDBSQLite
import Logging

/// The one report of a statement that held its connection: which connection, how long SQLite's own profile callback
/// says it ran, and the statement as prepared — never its bound values.
public enum SlowStatement {
  public static let thresholdMilliseconds = 100.0

  public static func isSlow(_ milliseconds: Double) -> Bool {
    milliseconds >= thresholdMilliseconds
  }

  public static func log(_ sql: String, milliseconds: Double, on connection: String, to log: Logger) {
    guard isSlow(milliseconds) else { return }
    log.warning("slow statement on \(connection): \(Int(milliseconds.rounded())) ms: \(sql.prefix(500))")
  }

  /// Has SQLite report every statement this connection finished, and this connection's name report the slow ones. The
  /// connection owns the report: SQLite releases it when it closes.
  public static func trace(on handle: OpaquePointer, connection: String, to log: Logger) {
    let report = Report(connection: connection, log: log)
    let stored = sqlite3_set_clientdata(handle, clientdataSlot, Unmanaged.passRetained(report).toOpaque()) {
      Unmanaged<Report>.fromOpaque($0!).release()
    }
    precondition(stored == SQLITE_OK, "the connection cannot hold its slow-statement report")
    sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, duration in
      Unmanaged<Report>.fromOpaque(context!).takeUnretainedValue()
        .report(OpaquePointer(statement!), nanoseconds: duration!.assumingMemoryBound(to: Int64.self).pointee)
      return SQLITE_OK
    }, Unmanaged.passUnretained(report).toOpaque())
  }
}

private let clientdataSlot = "wuhu.slow"

private final class Report: Sendable {
  let connection: String
  let log: Logger

  init(connection: String, log: Logger) {
    self.connection = connection
    self.log = log
  }

  func report(_ statement: OpaquePointer, nanoseconds: Int64) {
    SlowStatement.log(
      String(cString: sqlite3_sql(statement)).trimmedSQL,
      milliseconds: Double(nanoseconds) / 1_000_000,
      on: connection,
      to: log,
    )
  }
}
