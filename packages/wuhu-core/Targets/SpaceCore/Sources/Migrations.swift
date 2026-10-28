import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import Logging

enum Migrations {
  private static let all: [(id: String, migrate: @Sendable (Database) throws -> Void)] = [
    ("001", Migration001.apply), ("002", Migration002.apply), ("003", Migration003.apply), ("004", Migration004.apply),
    ("005", Migration005.apply), ("006", Migration006.apply), ("007", Migration007.apply), ("008", Migration008.apply),
    ("009", Migration009.apply), ("010", Migration010.apply), ("011", Migration011.apply), ("012", Migration012.apply),
    ("013", Migration013.apply),
  ]

  static func apply(to writer: any DatabaseWriter, log: Logger, date: DateGenerator) throws {
    var migrator = DatabaseMigrator()
    for (id, migrate) in all {
      migrator.registerMigration(id, foreignKeyChecks: .immediate) { db in
        log.notice("migration \(id): applying")
        let began = date.now
        try migrate(db)
        db.afterNextTransaction { _ in log.notice("migration \(id): applied in \(Int(date.now.timeIntervalSince(began) * 1000)) ms") }
      }
    }
    try writer.read { db in
      if try migrator.hasBeenSuperseded(db) {
        throw SpaceError.unknownMigrations(try migrator.appliedIdentifiers(db).subtracting(migrator.migrations).sorted())
      }
    }
    try migrator.migrate(writer)
  }
}
