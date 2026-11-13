#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB

/// The one place a host transaction writes a bucket row — the file writes still written as GRDB transactions
/// (`LiveFS`, `Space+DevLoop`) put their bytes here, in the transaction that names the hash — and the one place a
/// transaction reads one, which a move does for bytes a write left after its prefetch. The files cell deletes this
/// file with those writes.
enum InterimBlob {
  static func record(_ blob: Blob, in db: GRDB.Database) throws {
    if let key = blob.externalKey {
      try db.execute(
        sql: "INSERT OR IGNORE INTO bucket_objects (hash, size, line_count, content, object_key) VALUES (?, ?, ?, NULL, ?)",
        arguments: [blob.hash, blob.content.count, Substrate.lineCount(blob.content), key.raw],
      )
    } else {
      try db.execute(
        sql: "INSERT OR IGNORE INTO bucket_objects (hash, size, line_count, content, object_key) VALUES (?, ?, NULL, ?, NULL)",
        arguments: [blob.hash, blob.content.count, Data(blob.content)],
      )
    }
  }

  /// The bytes an inline row holds, read on the transaction's own connection: a move's step reads the file a write
  /// left after its prefetch, and only an external row has to be fetched outside it.
  static func inlineBytes(_ hash: String, in db: GRDB.Database) -> [UInt8]? {
    guard let row = try! Row.fetchOne(db, sql: "SELECT object_key, content FROM bucket_objects WHERE hash = ?", arguments: [hash]) else {
      preconditionFailure("a named hash has its bucket row: \(hash)")
    }
    guard (row["object_key"] as String?) == nil else { return nil }
    let content: Data? = row["content"]
    return content.map { Array($0) }
  }

  /// The hashes among `hashes` whose bytes are in the object store: the only ones a transaction cannot read.
  static func external(_ hashes: [String], in db: GRDB.Database) throws -> [String] {
    guard !hashes.isEmpty else { return [] }
    let marks = Array(repeating: "?", count: hashes.count).joined(separator: ", ")
    return try String.fetchAll(
      db, sql: "SELECT hash FROM bucket_objects WHERE object_key IS NOT NULL AND hash IN (\(marks))",
      arguments: StatementArguments(hashes),
    )
  }
}
