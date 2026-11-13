#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

@Cell
struct FilesCell {
  static let schema = [
    "CREATE TABLE file_document_checkpoint (\(ownerColumn), path TEXT NOT NULL, lineage INTEGER NOT NULL, seq INTEGER NOT NULL, rev INTEGER NOT NULL, PRIMARY KEY (owner, path))",
  ]

  static let owned = [
    "fs_heads": "grp", "fs_versions": "grp", "revisions": "grp", "revision_actors": "grp",
    "docs": "grp", "links": "grp", "doc_custom_attrs": "grp", "tables": "grp",
    "table_schema_versions": "grp", "table_rows": "grp",
  ]

  mutating func checkpoint(_ path: String, hash: String, lineage: Int64, seq: Int64, seedRev: Int64?, attribution: RevisionAttribution?, checkout: Int64?) throws {
    _ = try applyCheckpoint(SpacePath(validating: path), hash: hash, lineage: lineage, seq: seq, seedRev: seedRev, attribution: attribution, checkout: checkout)
  }

  mutating func moveMachineNotes(_ machine: String, to destination: GroupID) throws {
    let path = try SpacePath(validating: "/_/machines/\(machine)")
    if file(path) == nil { return }
    var transfer = try export(path)
    for i in transfer.nodes.indices {
      let target = try SpacePath(validating: transfer.nodes[i].head.path)
      transfer.nodes[i].index = transfer.nodes[i].index.reparented(to: target, in: destination, from: group)
    }
    let mtime = SQLiteDateFormat.string(from: Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000))
    let rev = try mintRevision(mtime, attribution: nil)
    for node in transfer.nodes { try remove(node.head, rev: rev, op: .delete) }
    ctx.send(FilesCell.ID(destination.rawValue)).adoptMachineNotes(transfer)
  }

  mutating func adoptMachineNotes(_ transfer: FileTransfer) throws {
    let path = try SpacePath(validating: transfer.path)
    guard let current = ctx.cell(MachineCell.ID(path.components[2])).record()?.group else { return }
    if current != group {
      var forwarded = transfer
      for i in forwarded.nodes.indices {
        let target = try SpacePath(validating: forwarded.nodes[i].head.path)
        forwarded.nodes[i].index = forwarded.nodes[i].index.reparented(to: target, in: current, from: group)
      }
      ctx.send(FilesCell.ID(current.rawValue)).adoptMachineNotes(forwarded)
      return
    }
    let mtime = SQLiteDateFormat.string(from: Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000))
    let rev = try mintRevision(mtime, attribution: nil)
    try ensureAncestorDirectories(path, rev: rev, mtime: mtime)
    for node in transfer.nodes.reversed() {
      let target = try SpacePath(validating: node.head.path)
      let existing = file(target)
      if let existing {
        if existing.kind == "directory", node.head.kind == "directory" { continue }
        let displaced = existing.kind == "directory" ? subtree(target) : [existing]
        for stale in displaced { try remove(stale, rev: rev, op: .delete) }
      }
      try install(FileTransfer(path: node.head.path, nodes: [node]), at: target, rev: rev, mtime: mtime, displaced: existing != nil)
    }
  }

  mutating func deleteMachineNotes(_ machine: String) throws {
    let path = try SpacePath(validating: "/_/machines/\(machine)")
    let mtime = SQLiteDateFormat.string(from: Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000))
    let rev = try mintRevision(mtime, attribution: nil)
    for node in subtree(path) { try remove(node, rev: rev, op: .delete) }
  }
}

extension FilesCell {
  var group: GroupID { GroupID(rawValue: id.key) }

  func file(_ path: SpacePath) -> FSHeadRow? {
    db.rows(FSHeadRow.at(path, in: group)).first
  }

  func currentRevision() -> Int64 {
    let key = id.key
    return db.rows(RevisionRow.where { $0.grp.eq(key) }.select { $0.rev.max() }).first! ?? 0
  }

  func revisionExists(_ rev: Int64) -> Bool { rev >= 1 && rev <= currentRevision() }

  mutating func mintRevision(_ mtime: String, attribution: RevisionAttribution?) throws -> Int64 {
    let rev = currentRevision() + 1
    let key = id.key
    try db.execute(RevisionRow.insert { RevisionRow(rev: rev, mtime: mtime, grp: key) })
    if let attribution {
      try db.execute(RevisionActorRow.insert { RevisionActorRow(grp: key, rev: rev, actor: attribution.actor, via: attribution.via) })
    }
    return rev
  }

  mutating func upsertHead(_ row: FSHeadRow) throws {
    precondition(row.grp == id.key)
    let key = id.key
    try db.execute(FSHeadRow.where { $0.grp.eq(key) && $0.path.eq(row.path) }.delete())
    try db.execute(FSHeadRow.insert { row })
  }

  mutating func appendVersion(_ path: String, rev: Int64, kind: String?, hash: String?, op: JournalOp, aux: String? = nil) throws {
    let key = id.key
    try db.execute(FSVersionRow.where { $0.grp.eq(key) && $0.path.eq(path) && $0.rev.eq(rev) }.delete())
    try db.execute(FSVersionRow.insert { FSVersionRow(grp: key, path: path, rev: rev, kind: kind, blobHash: hash, op: op.rawValue, aux: aux) })
  }

  func subtree(_ path: SpacePath) -> [FSHeadRow] {
    let key = id.key
    let lower = path.isRoot ? "/" : path.rawValue + "/", upper = path.isRoot ? "0" : path.rawValue + "0"
    return db.rows(FSHeadRow.where { $0.grp.eq(key) && ($0.path.eq(path.rawValue) || ($0.path.gte(lower) && $0.path.lt(upper))) }.order { $0.path })
  }

  func requireAncestorDirectories(_ path: SpacePath) throws {
    for dir in Self.ancestors(path) {
      if let existing = file(dir), existing.kind != "directory" { throw SpaceError.notADirectory(dir.rawValue) }
    }
  }

  mutating func ensureAncestorDirectories(_ path: SpacePath, rev: Int64, mtime: String) throws {
    try requireAncestorDirectories(path)
    for dir in Self.ancestors(path) where file(dir) == nil {
      try appendVersion(dir.rawValue, rev: rev, kind: "directory", hash: nil, op: .write)
      try upsertHead(FSHeadRow(grp: id.key, path: dir.rawValue, parentPath: dir.parent.rawValue, kind: "directory", blobHash: nil, size: 0, lineCount: nil, etag: "", rev: rev, mtime: mtime))
    }
  }

  private static func ancestors(_ path: SpacePath) -> [SpacePath] {
    var dir = path.parent, chain: [SpacePath] = []
    while !dir.isRoot { chain.append(dir); dir = dir.parent }
    return chain.reversed()
  }

  mutating func write(_ path: SpacePath, blob: Blob, ifMatch: VersionToken?, createOnly: Bool, mtime: String, attribution: RevisionAttribution?) throws -> Int64 {
    let head = file(path)
    if createOnly, head != nil { throw SpaceError.alreadyExists(path.rawValue) }
    try LiveFS.checkIfMatch(ifMatch, head: head, path: path)
    try Bucket.put(blob, in: &db)
    return try commitFile(path, blob: blob, head: head, mtime: mtime, attribution: attribution)
  }

  mutating func commitFile(_ path: SpacePath, blob: Blob, head: FSHeadRow?, mtime: String, attribution: RevisionAttribution?, op: JournalOp = .write, aux: String? = nil) throws -> Int64 {
    if head?.kind == "directory" { throw SpaceError.pathIsDirectory(path.rawValue) }
    try requireAncestorDirectories(path)
    if let head, head.blobHash == blob.hash { return head.rev }
    let rev = try mintRevision(mtime, attribution: attribution)
    try writeFile(path, blob: blob, rev: rev, mtime: mtime, op: op, aux: aux)
    return rev
  }

  mutating func writeFile(_ path: SpacePath, blob: Blob, rev: Int64, mtime: String, op: JournalOp = .write, aux: String? = nil) throws {
    try ensureAncestorDirectories(path, rev: rev, mtime: mtime)
    try appendVersion(path.rawValue, rev: rev, kind: "file", hash: blob.hash, op: op, aux: aux)
    try upsertHead(FSHeadRow(grp: id.key, path: path.rawValue, parentPath: path.parent.rawValue, kind: "file", blobHash: blob.hash, size: Int64(blob.content.count), lineCount: Substrate.lineCount(blob.content).map(Int64.init), etag: Substrate.etag(for: blob.hash), rev: rev, mtime: mtime))
    try index(path, .parse(path, group: group, content: blob.content))
  }

  mutating func touchTableNode(_ path: SpacePath, rev: Int64, mtime: String, op: JournalOp = .write, aux: String? = nil) throws {
    try appendVersion(path.rawValue, rev: rev, kind: "table", hash: nil, op: op, aux: aux)
    try upsertHead(FSHeadRow(grp: id.key, path: path.rawValue, parentPath: path.parent.rawValue, kind: "table", blobHash: nil, size: 0, lineCount: nil, etag: "", rev: rev, mtime: mtime))
  }

  mutating func remove(_ node: FSHeadRow, rev: Int64, op: JournalOp, aux: String? = nil) throws {
    let path = try SpacePath(validating: node.path)
    if node.kind == "table" { try retireTable(path, rev: rev) }
    try tombstone(path, rev: rev, op: op, aux: aux)
  }

  mutating func tombstone(_ path: SpacePath, rev: Int64, op: JournalOp, aux: String? = nil) throws {
    try appendVersion(path.rawValue, rev: rev, kind: nil, hash: nil, op: op, aux: aux)
    let key = id.key
    try db.execute(FSHeadRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.delete())
    try removeIndex(path)
    removed(path, rev: rev)
  }

  mutating func removed(_ path: SpacePath, rev: Int64) {
    guard path.isLive else { return }
    let document = DocumentCell.ID(group, path)
    if let lineage = ctx.cell(document).lineage() { ctx.send(document).removed(rev, lineage: lineage) }
  }

  mutating func delete(_ path: SpacePath, ifMatch: VersionToken?, mtime: String, attribution: RevisionAttribution?) throws {
    guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
    try LiveFS.checkIfMatch(ifMatch, head: head, path: path)
    let rev = try mintRevision(mtime, attribution: attribution)
    for node in subtree(path) { try remove(node, rev: rev, op: .delete) }
  }

  mutating func rmdir(_ path: SpacePath, mtime: String) throws -> Bool {
    guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
    guard head.kind == "directory" else { throw SpaceError.notADirectory(path.rawValue) }
    let key = id.key
    guard db.rows(FSHeadRow.where { $0.grp.eq(key) && $0.parentPath.eq(path.rawValue) }.limit(1)).isEmpty else { return false }
    let rev = try mintRevision(mtime, attribution: nil)
    try tombstone(path, rev: rev, op: .delete)
    return true
  }

  func fileContents(_ path: SpacePath) throws -> (rev: Int64, hash: String) {
    guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
    guard head.kind == "file", let hash = head.blobHash else { throw SpaceError.notAFile(path.rawValue) }
    return (head.rev, hash)
  }

  func entry(_ path: SpacePath) throws -> Entry {
    guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
    return Substrate.entry(from: head)
  }

  func page(_ path: SpacePath, from: String, limit: Int, budget: ListingBudget) throws -> ([Entry], String?, VersionToken) {
    if !path.isRoot {
      guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
      guard head.kind == "directory" else { throw SpaceError.notADirectory(path.rawValue) }
    }
    let key = id.key, start = (path.isRoot ? "/" : path.rawValue + "/") + from
    let children = db.rows(FSHeadRow.where { $0.grp.eq(key) && $0.parentPath.eq(path.rawValue) && $0.path.gte(start) }.order { $0.path }.limit(limit == Int.max ? limit : limit + 1))
    var budget = budget, entries: [Entry] = [], next: String?
    for child in children {
      let name = SpacePath.lastComponent(of: child.path)
      guard entries.count < limit else { next = name; break }
      try budget.consume(name)
      entries.append(Substrate.entry(from: child))
    }
    return (entries, next, VersionToken(rev: Int(currentRevision())))
  }
}
