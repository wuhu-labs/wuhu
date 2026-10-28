/// Page cache and mmap sizes for a space database's connections. The mmap size
/// is the 2 GiB `SQLITE_MAX_MMAP_SIZE` cap of Debian's libsqlite3; SQLite
/// silently clamps it to a lower build cap (Apple's system SQLite: 1 GiB).
public enum PageCache {
  public static let writerKiB = 65536
  public static let readerKiB = 16384
  public static let mmapBytes = 2_147_418_112

  public static func pragmas(cacheKiB: Int, schema: String? = nil) -> String {
    let prefix = schema.map { "\"" + $0.replacing("\"", with: "\"\"") + "\"." } ?? ""
    return "PRAGMA \(prefix)cache_size = -\(cacheKiB); PRAGMA \(prefix)mmap_size = \(mmapBytes)"
  }
}
