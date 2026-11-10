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
    ("013", Migration013.apply), ("014", Migration014.apply), ("015", Migration015.apply), ("016", Migration016.apply),
    ("017", Migration017.apply), ("018", Migration018.apply), ("019", Migration019.apply), ("020", Migration020.apply), ("021", Migration021.apply), ("022", Migration022.apply), ("023", Migration023.apply), ("024", Migration024.apply),
    ("025", Migration025.apply), ("026", Migration026.apply), ("027", Migration027.apply), ("028", Migration028.apply),
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
