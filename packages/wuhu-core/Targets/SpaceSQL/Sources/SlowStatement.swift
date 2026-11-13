import GRDB
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
}

extension Database {
  /// Has SQLite report every statement this connection finished, and this connection's name report the slow ones.
  public func traceSlowStatements(on connection: String, to log: Logger) {
    trace(options: .profile) { event in
      if case let .profile(statement: statement, duration: duration) = event {
        let milliseconds = duration * 1000
        guard SlowStatement.isSlow(milliseconds) else { return }
        SlowStatement.log(statement.sql, milliseconds: milliseconds, on: connection, to: log)
      }
    }
  }
}
