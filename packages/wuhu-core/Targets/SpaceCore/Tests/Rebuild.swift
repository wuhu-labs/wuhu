import GRDB
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import StructuredQueries

extension Space {
  func dump(_ sql: String) async throws -> [String] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: sql).map { row in
        (0 ..< row.count).map { CSV.field(from: row[$0]) }.joined(separator: "|")
      }
    }
  }

  func rebuildHeads() async throws {
    try await writer.write { db in
      try db.execute(sql: "DELETE FROM fs_heads")
      let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT v.grp AS grp, v.path AS path, v.kind AS kind, v.blob_hash AS blob_hash, v.rev AS rev, r.mtime AS mtime
        FROM fs_versions v JOIN revisions r ON r.rev = v.rev
        WHERE v.rev = (SELECT MAX(rev) FROM fs_versions v2 WHERE v2.grp = v.grp AND v2.path = v.path) AND v.kind IS NOT NULL
        """,
      )
      for row in rows {
        let path: String = row["path"]
        let kind: String = row["kind"]
        let blobHash: String? = row["blob_hash"]
        let rev: Int64 = row["rev"]
        let mtime: String = row["mtime"]
        let measure = kind == "file" ? try blobHash.map { try Substrate.measure($0, in: db) } : nil
        try Substrate.upsertHead(
          FSHeadRow(
            grp: row["grp"],
            path: path,
            parentPath: try SpacePath(validating: path).parent.rawValue,
            kind: kind,
            blobHash: blobHash,
            size: measure?.size ?? 0,
            lineCount: measure?.lineCount,
            etag: blobHash.map(Substrate.etag(for:)) ?? "",
            rev: rev,
            mtime: mtime,
          ),
          in: db,
        )
      }
    }
  }

  func rebuildInducedTables() async throws {
    try await blobs.write(
      writer,
      prefetching: { db in
        try FSHeadRow.where { $0.kind.eq("file") }.fetchAll(db).compactMap(\.blobHash)
      },
    ) { db, cache in
      try db.execute(sql: "DELETE FROM docs")
      try db.execute(sql: "DELETE FROM links")
      try db.execute(sql: "DELETE FROM doc_custom_attrs")
      for head in try FSHeadRow.where({ $0.kind.eq("file") }).fetchAll(db) {
        guard let hash = head.blobHash else { continue }
        try Induction.index(
          path: try SpacePath(validating: head.path),
          group: GroupID(rawValue: head.grp),
          content: try cache.blob(of: hash, in: db).content,
          in: db,
        )
      }
    }
  }

  func rebuildTable(_ path: SpacePath, in group: GroupID = .shared) async throws {
    try await writer.write { db in
      guard try Substrate.tableExists(path, group: group, in: db) else { throw SpaceError.notATable(path.rawValue) }
      let ceiling = try Substrate.maxRevision(in: db)
      let (header, rows) = try TableReplay.state(path, group: group, ceiling: ceiling, in: db)
      try db.execute(sql: "DROP TABLE IF EXISTS \(Tables.quoted(group, path))")
      try db.execute(sql: Tables.createMaterializedSQL(path, group: group, header: header))
      for row in rows {
        let cells = header.columns.map { row.cells[$0.name] ?? .null }
        try Tables.insertMaterializedRow(path, group: group, header: header, id: row.id, cells: cells, in: db)
      }
      try Tables.syncSequence(path, group: group, in: db)
    }
  }
}
