import GRDB
import WuweiNeo

extension Space {
  /// The space database as wuwei-neo's shared backend: its writer, and a reader the space closes with itself.
  public nonisolated func neoDatabase() throws -> any SharedDatabase {
    try writer.writeWithoutTransaction { try prepareConnection($0.sqliteConnection!) }
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { try prepareConnection($0.sqliteConnection!) }
    let reader = try DatabaseQueue(path: writer.path, configuration: configuration)
    neoReaders.withLock { $0.append(reader) }
    return NeoDatabase(writer: writer, reader: reader)
  }
}

private struct NeoDatabase: SharedDatabase {
  let writer: any DatabaseWriter
  let reader: DatabaseQueue

  func write(_ body: (OpaquePointer, AnyObject?) throws -> Void) throws {
    try writer.write { try body(try open($0), $0) }
  }

  func read(_ body: (OpaquePointer) throws -> Void) throws {
    try reader.read { try body(try open($0)) }
  }

  /// A worker's last pokes can outlive the space that closed under it: they fail instead of trapping.
  private func open(_ db: GRDB.Database) throws -> OpaquePointer {
    guard let handle = db.sqliteConnection else { throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "the space database is closed") }
    return handle
  }
}
