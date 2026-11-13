import GRDB

/// GRDB's row events, commit and rollback, forwarded to the space's ``ChangeSource``: the one place of the space's change tracking that names GRDB, replaced by `sqlite3_update_hook` on our own connection.
final class ChangeSourceFeeder: TransactionObserver {
  private let source: ChangeSource

  init(_ source: ChangeSource) {
    self.source = source
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

  func databaseDidChange() {}

  func databaseDidChange(with event: DatabaseEvent) { source.wrote(event.tableName) }

  func databaseWillCommit() throws {}

  func databaseDidCommit(_ db: Database) { source.committed() }

  func databaseDidRollback(_ db: Database) { source.rolledBack() }
}
