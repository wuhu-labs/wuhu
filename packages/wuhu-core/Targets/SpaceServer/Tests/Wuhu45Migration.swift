import Foundation
@testable import SpaceCore

// The shipped wuhu-45 compaction, applied as the rehearsal applies it: the
// exact file, with the user-table renames generated from the file itself
// spliced over its marker line.
enum Wuhu45Migration {
  static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "Backcompat/wuhu-45-migration.sql")

  static let renamesSQL = """
  SELECT 'ALTER TABLE "' || replace(path,'"','""') || '" RENAME TO "shared:' || replace(path,'"','""') || '";' FROM tables ORDER BY path
  """

  static func isApplied(to file: URL) throws -> Bool {
    try RawDatabase.open(file.path) { try $0.tableExists("schema_compactions") }
  }

  /// The script as the sqlite3 CLI takes it: the file with `file`'s renames spliced in.
  static func spliced(for file: URL) throws -> String {
    let renames = try RawDatabase.open(file.path) { try $0.strings(renamesSQL) }
    let script = try String(contentsOf: Self.script, encoding: .utf8)
    let marker = "\n-- @@USER_TABLE_RENAMES@@\n"
    precondition(script.contains(marker), "the migration lost its renames marker")
    return script.replacing(marker, with: "\n" + renames.joined(separator: "\n") + "\n")
  }

  /// The spliced script through one raw connection, which stops at the first error by itself; the CLI's dot-commands are dropped.
  static func apply(to file: URL) throws {
    let sql = try spliced(for: file).split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.hasPrefix(".") }.joined(separator: "\n")
    try RawDatabase.open(file.path) { try $0.execute(sql: sql) }
  }
}
