import GRDB
import StructuredQueries

extension SessionPrompts {
  static func invalidate(_ key: String, in db: Database) throws {
    try SessionPromptRow.where { $0.sessionID.eq(key) }.delete().execute(db)
  }
}
