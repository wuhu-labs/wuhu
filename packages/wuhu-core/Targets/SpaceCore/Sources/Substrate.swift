import Crypto
import Foundation
import GRDB
import KeelObjectStore
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

@Table("revision_actors")
struct RevisionActorRow {
  @Column("rev", primaryKey: true) var rev: Int64
  @Column("actor") var actor: String?
  @Column("via") var via: String
}

enum JournalOp: String {
  case write
  case delete
  case move
  case checkout
}

enum Substrate {
  static func mintRevision(
    mtime: String, group: GroupID, attribution: RevisionAttribution? = nil, in db: Database,
  ) throws -> Int64 {
    try db.execute(sql: "INSERT INTO revisions (mtime, grp) VALUES (?, ?)", arguments: [mtime, group.rawValue])
    let rev = db.lastInsertedRowID
    if let attribution {
      try RevisionActorRow.insert { RevisionActorRow(rev: rev, actor: attribution.actor, via: attribution.via) }.execute(db)
    }
    return rev
  }

  static func maxRevision(in db: Database) throws -> Int64 {
    try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(rev), 0) FROM revisions") ?? 0
  }

  static func revisionExists(_ rev: Int64, in db: Database) throws -> Bool {
    try Int64.fetchOne(db, sql: "SELECT 1 FROM revisions WHERE rev = ?", arguments: [rev]) != nil
  }

  static func blobHash(_ content: [UInt8]) -> String {
    hexEncoded(SHA256.hash(data: Data(content)))
  }

  static func record(_ blob: Blob, in db: Database) throws {
    guard let key = blob.externalKey else {
      guard try BlobRow.where({ $0.hash.eq(blob.hash) }).select({ $0.hash }).fetchOne(db) == nil else { return }
      try BlobRow.insert { BlobRow(hash: blob.hash, content: blob.content) }.execute(db)
      return
    }
    guard try BlobObjectRow.where({ $0.hash.eq(blob.hash) }).select({ $0.hash }).fetchOne(db) == nil else { return }
    try BlobObjectRow.insert {
      BlobObjectRow(
        hash: blob.hash,
        objectKey: key.raw,
        size: Int64(blob.content.count),
        lineCount: lineCount(blob.content).map(Int64.init),
      )
    }.execute(db)
  }

  static func externalKey(_ hash: String, in db: Database) throws -> ObjectKey? {
    guard let raw = try BlobObjectRow.where({ $0.hash.eq(hash) }).select({ $0.objectKey }).fetchOne(db) else {
      return nil
    }
    return try ObjectKey(raw)
  }

  static func storedBlob(_ hash: String, in db: Database) throws -> StoredBlob {
    if let key = try externalKey(hash, in: db) {
      return .external(key)
    }
    guard let content = try BlobRow.where({ $0.hash.eq(hash) }).select({ $0.content }).fetchOne(db) else {
      throw SpaceError.notFound(hash)
    }
    return .inline(content)
  }

  static func measure(_ hash: String, in db: Database) throws -> (size: Int64, lineCount: Int64?) {
    if let row = try BlobObjectRow.where({ $0.hash.eq(hash) }).fetchOne(db) {
      return (row.size, row.lineCount)
    }
    guard let content = try BlobRow.where({ $0.hash.eq(hash) }).select({ $0.content }).fetchOne(db) else {
      throw SpaceError.notFound(hash)
    }
    return (Int64(content.count), lineCount(content).map(Int64.init))
  }

  static func etag(for hash: String) -> String {
    String(hash.prefix(16))
  }

  static func lineCount(_ content: [UInt8]) -> Int? {
    guard let text = String(bytes: content, encoding: .utf8) else { return nil }
    if text.isEmpty { return 0 }
    let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    return text.hasSuffix("\n") ? newlines : newlines + 1
  }

  static func head(_ path: SpacePath, group: GroupID, in db: Database) throws -> FSHeadRow? {
    try FSHeadRow.where { $0.grp.eq(group.rawValue) && $0.path.eq(path.rawValue) }.fetchOne(db)
  }

  static func tableExists(_ path: SpacePath, group: GroupID, in db: Database) throws -> Bool {
    try TableNodeRow.where { $0.grp.eq(group.rawValue) && $0.path.eq(path.rawValue) }.fetchOne(db) != nil
  }

  static func upsertHead(_ row: FSHeadRow, in db: Database) throws {
    try db.execute(
      sql: """
      INSERT INTO fs_heads (grp, path, parent_path, kind, blob_hash, size, line_count, etag, rev, mtime)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(grp, path) DO UPDATE SET
        parent_path = excluded.parent_path, kind = excluded.kind, blob_hash = excluded.blob_hash,
        size = excluded.size, line_count = excluded.line_count, etag = excluded.etag,
        rev = excluded.rev, mtime = excluded.mtime
      """,
      arguments: [
        row.grp, row.path, row.parentPath, row.kind, row.blobHash,
        row.size, row.lineCount, row.etag, row.rev, row.mtime,
      ],
    )
  }

  static func appendVersion(
    group: GroupID,
    path: String,
    rev: Int64,
    kind: String?,
    blobHash: String?,
    op: JournalOp,
    aux: String? = nil,
    in db: Database,
  ) throws {
    try db.execute(
      sql: "INSERT OR REPLACE INTO fs_versions (grp, path, rev, kind, blob_hash, op, aux) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [group.rawValue, path, rev, kind, blobHash, op.rawValue, aux],
    )
  }

  static func descendantHeads(of dir: SpacePath, group: GroupID, in db: Database) throws -> [FSHeadRow] {
    let lower = dir.rawValue + "/"
    let upper = dir.rawValue + "0"
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT * FROM fs_heads WHERE grp = ? AND (path = ? OR (path >= ? AND path < ?)) ORDER BY LENGTH(path) DESC",
      arguments: [group.rawValue, dir.rawValue, lower, upper],
    )
    return rows.map(FSHeadRow.init(row:))
  }

  static func writeFile(
    _ path: SpacePath,
    group: GroupID,
    blob: Blob,
    rev: Int64,
    mtime: String,
    op: JournalOp = .write,
    aux: String? = nil,
    in db: Database,
  ) throws {
    try ensureAncestorDirectories(path, group: group, rev: rev, mtime: mtime, in: db)
    try record(blob, in: db)
    try appendVersion(group: group, path: path.rawValue, rev: rev, kind: "file", blobHash: blob.hash, op: op, aux: aux, in: db)
    try upsertHead(
      FSHeadRow(
        grp: group.rawValue, path: path.rawValue, parentPath: path.parent.rawValue, kind: "file", blobHash: blob.hash,
        size: Int64(blob.content.count), lineCount: lineCount(blob.content).map(Int64.init),
        etag: etag(for: blob.hash), rev: rev, mtime: mtime,
      ),
      in: db,
    )
    try Induction.index(path: path, group: group, content: blob.content, in: db)
  }

  static func entryKind(_ kind: String) -> Entry.Kind {
    switch kind {
    case "directory": .directory
    case "table": .table
    default: .file
    }
  }

  static func touchTableNode(
    _ path: SpacePath,
    group: GroupID,
    rev: Int64,
    mtime: String,
    op: JournalOp = .write,
    aux: String? = nil,
    in db: Database,
  ) throws {
    try appendVersion(group: group, path: path.rawValue, rev: rev, kind: "table", blobHash: nil, op: op, aux: aux, in: db)
    try upsertHead(
      FSHeadRow(
        grp: group.rawValue, path: path.rawValue, parentPath: path.parent.rawValue, kind: "table",
        blobHash: nil, size: 0, lineCount: nil, etag: "", rev: rev, mtime: mtime,
      ),
      in: db,
    )
  }

  static func entry(from head: FSHeadRow) -> Entry {
    Entry(
      name: SpacePath.lastComponent(of: head.path),
      kind: entryKind(head.kind),
      size: Int(head.size),
      lineCount: head.lineCount.map(Int.init),
      token: VersionToken(rev: Int(head.rev)),
      mtime: (try? SQLiteDateFormat.date(from: head.mtime)) ?? Date(timeIntervalSince1970: 0),
    )
  }

  static func ensureAncestorDirectories(
    _ path: SpacePath,
    group: GroupID,
    rev: Int64,
    mtime: String,
    in db: Database,
  ) throws {
    var ancestor = path.parent
    var chain: [SpacePath] = []
    while !ancestor.isRoot {
      chain.append(ancestor)
      ancestor = ancestor.parent
    }
    for dir in chain.reversed() {
      if let existing = try head(dir, group: group, in: db) {
        if existing.kind != "directory" { throw SpaceError.notADirectory(dir.rawValue) }
        continue
      }
      try appendVersion(group: group, path: dir.rawValue, rev: rev, kind: "directory", blobHash: nil, op: .write, in: db)
      try upsertHead(
        FSHeadRow(
          grp: group.rawValue, path: dir.rawValue, parentPath: dir.parent.rawValue, kind: "directory",
          blobHash: nil, size: 0, lineCount: nil, etag: "", rev: rev, mtime: mtime,
        ),
        in: db,
      )
    }
  }
}

extension SpacePath {
  static func lastComponent(of raw: String) -> String {
    (try? SpacePath(validating: raw))?.lastComponent ?? raw
  }
}

extension FSHeadRow {
  init(row: Row) {
    self.init(
      grp: row["grp"],
      path: row["path"],
      parentPath: row["parent_path"],
      kind: row["kind"],
      blobHash: row["blob_hash"],
      size: row["size"],
      lineCount: row["line_count"],
      etag: row["etag"],
      rev: row["rev"],
      mtime: row["mtime"],
    )
  }
}
