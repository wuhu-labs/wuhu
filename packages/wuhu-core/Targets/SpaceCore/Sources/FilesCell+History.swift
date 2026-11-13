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

@Selection
struct HistoricalNode {
  let path: String
  let kind: String?
  let blobHash: String?
  let rev: Int64
  let mtime: String
}

@Selection private struct JournalEntry {
  var rev: Int64
  var mtime: String
  var op: String
  var aux: String?
}

extension FilesCell {
  func requireRevision(_ rev: Int64) throws {
    guard revisionExists(rev) else { throw SpaceError.invalidRevision(Int(rev)) }
  }

  func resolve(_ path: String, at ceiling: Int64) -> HistoricalNode? {
    let key = id.key
    let row = db.rows(FSVersionRow.where { $0.grp.eq(key) && $0.path.eq(path) && $0.rev.lte(ceiling) }
      .order { $0.rev.desc() }.limit(1)
      .join(RevisionRow.all) { $0.grp.eq($1.grp) && $0.rev.eq($1.rev) }
      .select { HistoricalNode.Columns(path: $0.path, kind: $0.kind, blobHash: $0.blobHash, rev: $0.rev, mtime: $1.mtime) }).first
    return row?.kind == nil ? nil : row
  }

  func historical(_ path: SpacePath, at ceiling: Int64) throws -> HistoricalNode {
    try requireRevision(ceiling)
    guard let node = resolve(path.rawValue, at: ceiling) else { throw SpaceError.notFound(path.rawValue) }
    return node
  }

  func historicalFile(_ path: SpacePath, at ceiling: Int64) throws -> HistoricalNode {
    let node = try historical(path, at: ceiling)
    guard node.kind == "file" else { throw SpaceError.notAFile(path.rawValue) }
    return node
  }

  func historicalPage(_ path: SpacePath, at ceiling: Int64, from: String, limit: Int, budget: ListingBudget) throws -> ([HistoricalNode], String?) {
    try requireRevision(ceiling)
    if !path.isRoot {
      let node = try historical(path, at: ceiling)
      guard node.kind == "directory" else { throw SpaceError.notADirectory(path.rawValue) }
    }
    let key = id.key, prefix = path.isRoot ? "/" : path.rawValue + "/"
    let start = prefix + from, end = String(prefix.dropLast()) + "0"
    let nodes = db.rows(FSVersionRow.where {
      $0.grp.eq(key) && $0.path.gte(start) && $0.path.lt(end) && $0.kind.isNot(nil) &&
        #sql("instr(substr(\($0.path), length(\(bind: prefix)) + 1), '/') = 0", as: Bool.self) &&
        $0.rev.eq(#sql("(SELECT MAX(rev) FROM fs_versions v2 WHERE v2.grp = \($0.grp) AND v2.path = \($0.path) AND v2.rev <= \(bind: ceiling))", as: Int64.self))
    }.order { $0.path }.limit(limit == Int.max ? limit : limit + 1)
      .join(RevisionRow.all) { $0.grp.eq($1.grp) && $0.rev.eq($1.rev) }
      .select { HistoricalNode.Columns(path: $0.path, kind: $0.kind, blobHash: $0.blobHash, rev: $0.rev, mtime: $1.mtime) })
    var budget = budget, result: [HistoricalNode] = [], next: String?
    for node in nodes {
      let name = SpacePath.lastComponent(of: node.path)
      guard result.count < limit else { next = name; break }
      try budget.consume(name)
      result.append(node)
    }
    return (result, next)
  }

  func history(_ path: SpacePath, after: Int, limit: Int) -> [(Rev, Date, Change)] {
    let key = id.key
    return db.rows(FSVersionRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) && $0.rev.gt(Int64(after)) }
      .order { $0.rev }.limit(limit)
      .join(RevisionRow.all) { $0.grp.eq($1.grp) && $0.rev.eq($1.rev) }
      .select { JournalEntry.Columns(rev: $0.rev, mtime: $1.mtime, op: $0.op, aux: $0.aux) }).map { row in
      let change: Change = switch JournalOp(rawValue: row.op)! {
      case .write: .write(VersionToken(rev: Int(row.rev)))
      case .delete: .delete
      case .move: .move(to: row.aux!)
      case .checkout: .checkout(fromRev: Int(row.aux!)!)
      }
      return (Rev(Int(row.rev)), try! SQLiteDateFormat.date(from: row.mtime), change)
    }
  }

  func attributions(_ revisions: [Int64]) -> [Rev: RevisionAttribution] {
    let key = id.key
    return Dictionary(uniqueKeysWithValues: db.rows(RevisionActorRow.where { $0.grp.eq(key) && $0.rev.in(revisions) })
      .map { (Rev(Int($0.rev)), RevisionAttribution(actor: $0.actor, via: $0.via)) })
  }

  func tableSchema(_ path: SpacePath, at ceiling: Int64?) throws -> (header: TableHeader, token: VersionToken) {
    if let ceiling {
      let node = try historical(path, at: ceiling)
      guard node.kind == "table" else { throw SpaceError.notATable(path.rawValue) }
      return (try tableState(path, ceiling: ceiling).0, VersionToken(rev: Int(node.rev)))
    }
    guard let head = file(path) else { throw SpaceError.notFound(path.rawValue) }
    guard head.kind == "table" else { throw SpaceError.notATable(path.rawValue) }
    return (try currentHeader(path), VersionToken(rev: Int(head.rev)))
  }

  mutating func checkout(_ path: SpacePath, at ceiling: Int64, restored: Blob?, ifMatch: VersionToken?, createOnly: Bool, mtime: String, attribution: RevisionAttribution?) throws -> Int64 {
    try requireRevision(ceiling)
    let resolved = resolve(path.rawValue, at: ceiling), head = file(path)
    if resolved?.kind == "directory" { throw SpaceError.notAFile(path.rawValue) }
    if createOnly, head != nil { throw SpaceError.alreadyExists(path.rawValue) }
    try LiveFS.checkIfMatch(ifMatch, head: head, path: path)
    guard resolved != nil || head != nil else { throw SpaceError.notFound(path.rawValue) }
    if let resolved, resolved.kind == "file", let head, head.kind == "file", resolved.blobHash == head.blobHash {
      if path.isLive { ctx.send(DocumentCell.ID(group, path)).removed(head.rev) }
      return head.rev
    }
    let rev = try mintRevision(mtime, attribution: attribution)
    switch resolved?.kind {
    case "file":
      if head?.kind == "table" { try retireTable(path, rev: rev) }
      try writeFile(path, blob: restored!, rev: rev, mtime: mtime, op: .checkout, aux: String(ceiling))
    case "table":
      try removeIndex(path)
      try restoreTable(path, ceiling: ceiling, rev: rev, mtime: mtime)
    default: try remove(head!, rev: rev, op: .checkout, aux: String(ceiling))
    }
    if resolved != nil, path.isLive { ctx.send(DocumentCell.ID(group, path)).removed(rev) }
    return rev
  }
}

extension FilesCell {
  func linkSources(into path: String) -> [String] {
    let key = id.key, lower = path + "/", upper = path + "0"
    return db.rows(LinkRow.where { $0.grp.eq(key) && $0.dstGroup.eq(key) && ($0.dst.eq(path) || ($0.dst.gte(lower) && $0.dst.lt(upper))) }.select { $0.src }.distinct().order { $0 }).map { $0 }
  }
}
