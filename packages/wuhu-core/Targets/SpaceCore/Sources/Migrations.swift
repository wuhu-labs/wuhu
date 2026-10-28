import GRDB

enum Migrations {
  static func apply(to writer: any DatabaseWriter) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("001", foreignKeyChecks: .immediate, migrate: Migration001.apply)
    migrator.registerMigration("002", foreignKeyChecks: .immediate, migrate: Migration002.apply)
    migrator.registerMigration("003", foreignKeyChecks: .immediate, migrate: Migration003.apply)
    migrator.registerMigration("004", foreignKeyChecks: .immediate, migrate: Migration004.apply)
    migrator.registerMigration("005", foreignKeyChecks: .immediate, migrate: Migration005.apply)
    migrator.registerMigration("006", foreignKeyChecks: .immediate, migrate: Migration006.apply)
    migrator.registerMigration("007", foreignKeyChecks: .immediate, migrate: Migration007.apply)
    migrator.registerMigration("008", foreignKeyChecks: .immediate, migrate: Migration008.apply)
    migrator.registerMigration("009", foreignKeyChecks: .immediate, migrate: Migration009.apply)
    migrator.registerMigration("010", foreignKeyChecks: .immediate, migrate: Migration010.apply)
    migrator.registerMigration("011", foreignKeyChecks: .immediate, migrate: Migration011.apply)
    migrator.registerMigration("012", foreignKeyChecks: .immediate, migrate: Migration012.apply)
    try writer.read { db in
      if try migrator.hasBeenSuperseded(db) {
        throw SpaceError.unknownMigrations(try migrator.appliedIdentifiers(db).subtracting(migrator.migrations).sorted())
      }
    }
    try migrator.migrate(writer)
  }
}
