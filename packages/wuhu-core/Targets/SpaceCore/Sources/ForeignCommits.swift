/// A commit another connection made — in a roll, the other server on the file — moves `PRAGMA data_version` on the writer, which the writer's update hook never hears: reading it once a second wakes every table for such a commit.
final class ForeignCommits: Sendable {
  static let interval: Duration = .seconds(1)

  private let database: WuweiDatabase
  private let changes: ChangeSource
  private let clock: any Clock<Duration>
  private let baseline: Int

  init(database: WuweiDatabase, changes: ChangeSource, clock: any Clock<Duration>) throws {
    self.database = database
    self.changes = changes
    self.clock = clock
    baseline = try Self.dataVersion(database)
  }

  /// Runs until the task scope cancels it: the space is closing, and the writer goes after.
  func watch() async {
    var version = baseline
    while true {
      do { try await clock.sleep(for: Self.interval) } catch { return }
      guard let commit = commit(since: version) else { continue }
      version = commit.version
      changes.publish(commit.tables)
    }
  }

  /// The value now and every table of the database, when a commit by another connection moved it since `version`; nil when nothing did.
  private func commit(since version: Int) -> (version: Int, tables: Set<String>)? {
    do {
      return try database.accessWriter(label: "space.foreignCommits") { handle in
        let db = MigrationDB(handle: handle)
        let current = try Self.dataVersion(db)
        guard current != version else { return nil }
        return (current, Set(try db.strings("SELECT name FROM sqlite_master WHERE type = 'table'")))
      }
    } catch {
      preconditionFailure("could not read the space's data_version: \(error)")
    }
  }

  private static func dataVersion(_ database: WuweiDatabase) throws -> Int {
    try database.accessWriter(label: "space.foreignCommits") { try dataVersion(MigrationDB(handle: $0)) }
  }

  private static func dataVersion(_ db: MigrationDB) throws -> Int {
    try db.int("PRAGMA data_version")!
  }
}
