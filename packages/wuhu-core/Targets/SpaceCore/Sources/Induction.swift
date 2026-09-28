import DocIndex
import Foundation
import GRDB
import Logging
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

enum Induction {
  static func index(path: SpacePath, group: GroupID, content: [UInt8], in db: Database) throws {
    try remove(path: path, group: group, in: db)
    guard let meta = parse(path: path, content: content) else { return }

    try DocRow.insert {
      DocRow(grp: group.rawValue, path: path.rawValue, title: meta.title, kind: meta.kind, status: meta.status)
    }.execute(db)

    let targets = meta.links.map { (group.rawValue, $0) } + meta.groupLinks.map { ($0.group, $0.path) }
    for (dstGroup, dst) in targets {
      try db.execute(
        sql: "INSERT OR IGNORE INTO links (grp, src, dst_grp, dst) VALUES (?, ?, ?, ?)",
        arguments: [group.rawValue, path.rawValue, dstGroup, dst.rawValue],
      )
    }

    for attr in meta.customAttrs {
      for (ord, value) in flatten(attr.value).enumerated() {
        try DocCustomAttrRow.insert {
          DocCustomAttrRow(grp: group.rawValue, path: path.rawValue, name: attr.name, ord: Int64(ord), value: value)
        }.execute(db)
      }
    }
  }

  static func remove(path: SpacePath, group: GroupID, in db: Database) throws {
    try db.execute(sql: "DELETE FROM docs WHERE grp = ? AND path = ?", arguments: [group.rawValue, path.rawValue])
    try db.execute(sql: "DELETE FROM links WHERE grp = ? AND src = ?", arguments: [group.rawValue, path.rawValue])
    try db.execute(sql: "DELETE FROM doc_custom_attrs WHERE grp = ? AND path = ?", arguments: [group.rawValue, path.rawValue])
  }

  private static func flatten(_ value: DocMeta.AttrValue) -> [String] {
    switch value {
    case let .scalar(text): [text]
    case let .array(elements): elements
    case let .jsonObject(json): [json]
    }
  }

  private static func parse(path: SpacePath, content: [UInt8]) -> DocMeta? {
    guard let text = String(bytes: content, encoding: .utf8) else { return nil }
    switch documentKind(of: path) {
    case .markdown: return DocIndex.parse(markdown: text, at: path)
    case .html: return DocIndex.parse(html: text, at: path)
    case .none: return nil
    }
  }

  private enum DocumentKind { case markdown, html }

  static func isDocument(_ path: SpacePath) -> Bool {
    documentKind(of: path) != nil
  }

  private static func documentKind(of path: SpacePath) -> DocumentKind? {
    guard let name = path.lastComponent?.lowercased() else { return nil }
    if name.hasSuffix(".md") || name.hasSuffix(".markdown") { return .markdown }
    if name.hasSuffix(".html") || name.hasSuffix(".htm") { return .html }
    return nil
  }
}

extension Space {
  static let linksCompaction: String = "wuhu-45-links"

  /// Re-induces every document's docs, links and custom attrs once on a file
  /// compacted by wuhu-45, whose rows an older parser wrote. A document whose
  /// blob can't be read keeps its old rows and is logged; the compaction is
  /// recorded regardless, so one bad blob never keeps the server from starting.
  public func reindexLinks() async throws {
    guard try await !writer.read({ db in try SpaceMeta.hasCompaction(Self.linksCompaction, in: db) }) else { return }
    var documents: [(group: GroupID, path: SpacePath, hash: String, content: [UInt8])] = []
    for head in try await writer.read({ db in try Self.documentHeads(in: db) }) {
      do {
        let content = try await blobs.read(writer) { db, cache in try cache.blob(of: head.hash, in: db).content }
        documents.append((head.group, head.path, head.hash, content))
      } catch {
        log.warning("\(Self.linksCompaction): skipped \(head.group.rawValue):\(head.path.rawValue), its blob is unreadable: \(error)")
      }
    }
    let loaded = documents
    try await writer.write { db in
      guard try !SpaceMeta.hasCompaction(Self.linksCompaction, in: db) else { return }
      for document in loaded where try Self.headHash(document.group, document.path, in: db) == document.hash {
        try Induction.index(path: document.path, group: document.group, content: document.content, in: db)
      }
      try SpaceMeta.recordCompaction(Self.linksCompaction, in: db)
    }
  }

  private static func headHash(_ group: GroupID, _ path: SpacePath, in db: Database) throws -> String? {
    try String.fetchOne(
      db, sql: "SELECT blob_hash FROM fs_heads WHERE grp = ? AND path = ?", arguments: [group.rawValue, path.rawValue],
    )
  }

  private static func documentHeads(in db: Database) throws -> [(group: GroupID, path: SpacePath, hash: String)] {
    try Row.fetchAll(db, sql: "SELECT grp, path, blob_hash FROM fs_heads WHERE kind = 'file' AND blob_hash IS NOT NULL ORDER BY grp, path")
      .compactMap { row in
        guard let path = try? SpacePath(validating: row["path"]), Induction.isDocument(path) else { return nil }
        return (GroupID(rawValue: row["grp"]), path, row["blob_hash"])
      }
  }
}
