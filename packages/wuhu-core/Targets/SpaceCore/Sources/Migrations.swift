import Dependencies
import Logging

typealias MigrationBody = @Sendable (MigrationDB) throws -> Void

/// One baseline migration: the identifier it is frozen under and the body that runs once.
typealias Migration = (id: String, migrate: MigrationBody)

/// A family of addressables. Its chain runs after the baseline, in this order.
enum MigrationFamily: String, CaseIterable, Sendable {
  case tenancy
  case group
  case conversations
  case agents
  case machines
}

/// A family's migrations, in the order they run. The runner records them by position: `<family>/0001`, `<family>/0002`, …
struct MigrationChain {
  let family: MigrationFamily
  let migrations: [MigrationBody]

  init(_ family: MigrationFamily, migrations: [MigrationBody] = []) {
    self.family = family
    self.migrations = migrations
  }
}

enum Migrations {
  /// 001–056, frozen: an existing database opens as it is. A new migration goes in its family's chain below.
  static let baseline: [Migration] = [
    ("001", Migration001.apply), ("002", Migration002.apply), ("003", Migration003.apply), ("004", Migration004.apply),
    ("005", Migration005.apply), ("006", Migration006.apply), ("007", Migration007.apply), ("008", Migration008.apply),
    ("009", Migration009.apply), ("010", Migration010.apply), ("011", Migration011.apply), ("012", Migration012.apply),
    ("013", Migration013.apply), ("014", Migration014.apply), ("015", Migration015.apply), ("016", Migration016.apply),
    ("017", Migration017.apply), ("018", Migration018.apply), ("019", Migration019.apply), ("020", Migration020.apply), ("021", Migration021.apply), ("022", Migration022.apply), ("023", Migration023.apply), ("024", Migration024.apply),
    ("025", Migration025.apply), ("026", Migration026.apply), ("027", Migration027.apply), ("028", Migration028.apply), ("029", Migration029.apply),
    ("030", Migration030.apply), ("031", Migration031.apply), ("032", Migration032.apply), ("033", Migration033.apply), ("034", Migration034.apply), ("035", Migration035.apply), ("036", Migration036.apply), ("037", Migration037.apply), ("038", Migration038.apply), ("039", Migration039.apply), ("040", Migration040.apply), ("041", Migration041.apply), ("042", Migration042.apply), ("043", Migration043.apply), ("044", Migration044.apply), ("045", Migration045.apply), ("046", Migration046.apply), ("047", Migration047.apply), ("048", Migration048.apply), ("049", Migration049.apply), ("050", Migration050.apply), ("051", Migration051.apply), ("052", Migration052.apply), ("053", Migration053.apply), ("054", Migration054.apply),
    ("055", Migration055.apply), ("056", Migration056.apply),
  ]

  /// Every family's chain; a family with nothing to migrate yet stays empty.
  static let chains: [MigrationChain] = [
    MigrationChain(.tenancy),
    MigrationChain(.group),
    MigrationChain(.conversations, migrations: [ConversationsMigration001.apply]),
    MigrationChain(.agents),
    MigrationChain(.machines),
  ]

  static func apply(db: MigrationDB, log: Logger, date: DateGenerator) throws {
    try MigrationRunner(db: db, log: log, date: date, baseline: baseline, chains: chains).migrate()
  }
}
