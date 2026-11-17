import CSQLiteConfig
import GRDBSQLite

public enum SQLiteLibrary {
  /// SQLite takes this setting only before the process's first open, so open sites touch this first.
  public static let memoryStatisticsOff: Void = {
    _ = sqlite_memory_statistics_off()
  }()
}
