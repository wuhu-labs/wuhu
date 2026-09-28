import Foundation
import GRDB
import struct SpaceContract.GroupID
import SpaceFS

struct HistoricalFS: SpaceVFS {
  let group: GroupID
  let writer: any DatabaseWriter
  let blobs: BlobStore
  let ceiling: Int64

  struct ResolvedNode {
    let path: String
    let kind: String
    let blobHash: String?
    let rev: Int64
    let mtime: String
  }

  func read(_ path: String) async throws -> (VersionToken, Data) {
    let p = try LiveFS.validated(path)
    let group = group
    return try await blobs.read(writer) { db, cache in
      try Self.requireRevision(ceiling, in: db)
      guard let node = try Self.resolve(p.rawValue, group: group, ceiling: ceiling, in: db) else {
        throw SpaceError.notFound(p.rawValue)
      }
      guard node.kind == "file", let hash = node.blobHash else { throw SpaceError.notAFile(p.rawValue) }
      return (VersionToken(rev: Int(node.rev)), Data(try cache.blob(of: hash, in: db).content))
    }
  }

  func write(_ path: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken {
    throw SpaceError.readOnlyView(path)
  }

  func delete(_ path: String, ifMatch _: VersionToken?) async throws {
    throw SpaceError.readOnlyView(path)
  }

  func move(_ path: String, to _: String) async throws {
    throw SpaceError.readOnlyView(path)
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    let p = try LiveFS.validated(path)
    let group = group
    return try await writer.read { db in
      try Self.requireRevision(ceiling, in: db)
      if !p.isRoot {
        guard let node = try Self.resolve(p.rawValue, group: group, ceiling: ceiling, in: db) else {
          throw SpaceError.notFound(p.rawValue)
        }
        guard node.kind == "directory" else { throw SpaceError.notADirectory(p.rawValue) }
      }
      let live = try Self.children(of: p, group: group, ceiling: ceiling, in: db)
      var entries: [Entry] = []
      for node in live where (try? SpacePath(validating: node.path))?.parent == p {
        entries.append(try Self.entry(from: node, in: db))
      }
      return (VersionToken(rev: Int(ceiling)), entries.sorted { $0.name < $1.name })
    }
  }

  func stat(_ path: String) async throws -> Entry {
    let p = try LiveFS.validated(path)
    let group = group
    return try await writer.read { db in
      try Self.requireRevision(ceiling, in: db)
      guard let node = try Self.resolve(p.rawValue, group: group, ceiling: ceiling, in: db) else {
        throw SpaceError.notFound(p.rawValue)
      }
      return try Self.entry(from: node, in: db)
    }
  }

  static func requireRevision(_ ceiling: Int64, in db: Database) throws {
    guard try Substrate.revisionExists(ceiling, in: db) else {
      throw SpaceError.invalidRevision(Int(ceiling))
    }
  }

  static func resolve(_ path: String, group: GroupID, ceiling: Int64, in db: Database) throws -> ResolvedNode? {
    guard let row = try Row.fetchOne(
      db,
      sql: """
      SELECT v.path AS path, v.kind AS kind, v.blob_hash AS blob_hash, v.rev AS rev, r.mtime AS mtime
      FROM fs_versions v JOIN revisions r ON r.rev = v.rev
      WHERE v.grp = ? AND v.path = ? AND v.rev <= ? ORDER BY v.rev DESC LIMIT 1
      """,
      arguments: [group.rawValue, path, ceiling],
    ) else { return nil }
    guard let kind: String = row["kind"] else { return nil }
    return ResolvedNode(path: row["path"], kind: kind, blobHash: row["blob_hash"], rev: row["rev"], mtime: row["mtime"])
  }

  // The nodes directly under `parent` as of `ceiling`. The path range keeps
  // the scan to `parent`'s subtree on the (path, rev) key: every path under
  // `/a/` sorts between `/a/` and `/a0`, `0` being the byte after `/`.
  static func children(of parent: SpacePath, group: GroupID, ceiling: Int64, in db: Database) throws -> [ResolvedNode] {
    let prefix = parent.isRoot ? "/" : parent.rawValue + "/"
    let rows = try Row.fetchAll(
      db,
      sql: """
      SELECT v.path AS path, v.kind AS kind, v.blob_hash AS blob_hash, v.rev AS rev, r.mtime AS mtime
      FROM fs_versions v JOIN revisions r ON r.rev = v.rev
      WHERE v.grp = ? AND v.path > ? AND v.path < ? AND instr(substr(v.path, length(?) + 1), '/') = 0
        AND v.rev = (SELECT MAX(rev) FROM fs_versions v2 WHERE v2.grp = v.grp AND v2.path = v.path AND v2.rev <= ?)
        AND v.kind IS NOT NULL
      """,
      arguments: [group.rawValue, prefix, String(prefix.dropLast()) + "0", prefix, ceiling],
    )
    return rows.map { ResolvedNode(path: $0["path"], kind: $0["kind"], blobHash: $0["blob_hash"], rev: $0["rev"], mtime: $0["mtime"]) }
  }

  static func entry(from node: ResolvedNode, in db: Database) throws -> Entry {
    let measure = node.kind == "file" ? try node.blobHash.map { try Substrate.measure($0, in: db) } : nil
    return Entry(
      name: SpacePath.lastComponent(of: node.path),
      kind: Substrate.entryKind(node.kind),
      size: Int(measure?.size ?? 0),
      lineCount: measure?.lineCount.map(Int.init),
      token: VersionToken(rev: Int(node.rev)),
      mtime: (try? SQLiteDateFormat.date(from: node.mtime)) ?? Date(timeIntervalSince1970: 0),
    )
  }
}
