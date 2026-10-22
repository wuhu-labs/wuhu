import GRDB

enum Migrations {
  static func apply(to writer: any DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("001", foreignKeyChecks: .immediate, migrate: Migration001.apply)
    migrator.registerMigration("002", foreignKeyChecks: .immediate, migrate: Migration002.apply)
    migrator.registerMigration("003", foreignKeyChecks: .immediate, migrate: Migration003.apply)
    try writer.read { db in
      if try migrator.hasBeenSuperseded(db) {
        throw SpaceError.unknownMigrations(try migrator.appliedIdentifiers(db).subtracting(migrator.migrations).sorted())
      }
    }
    try migrator.migrate(writer)
  }
}
