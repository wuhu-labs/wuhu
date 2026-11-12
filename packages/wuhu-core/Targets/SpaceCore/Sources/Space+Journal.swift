#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

@Selection private struct JournalEntry {
  var rev: Int64
  var mtime: String
  var op: String
  var aux: String?
}

extension Space {
  /// With `replacing`, an existing file at `destination` is replaced in the same revision; any other existing entry still refuses the move.
  /// Across groups the move is a delete in `group` and a create in `destinationGroup`, in one revision recorded for `acting`.
  public func move(
    _ path: String, in group: GroupID, to destination: String, in destinationGroup: GroupID, replacing: Bool, acting: GroupID,
    attribution: RevisionAttribution? = nil,
  ) async throws {
    try await live(group, acting: acting, attribution: attribution).move(
      MachineFolders.stored(path, mutating: true, in: runtime),
      to: MachineFolders.stored(destination, mutating: true, in: runtime),
      in: destinationGroup,
      replacing: replacing,
    )
  }

  public func writeFile(_ path: SpacePath, data: Data, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, ifMatch: VersionToken?, createOnly: Bool) async throws -> VersionToken {
    try await live(group, acting: acting, attribution: attribution).write(MachineFolders.stored(path, mutating: true, in: runtime).rawValue, data, ifMatch: ifMatch, createOnly: createOnly)
  }

  public func removeEmptyDirectory(_ path: SpacePath, in group: GroupID, acting: GroupID) async throws -> Bool {
    guard !path.isRoot, !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      try MachineFolders.requireStored(path, in: db)
      guard let head = try Substrate.head(path, group: group, in: db) else { throw SpaceError.notFound(path.rawValue) }
      guard head.kind == "directory" else { throw SpaceError.notADirectory(path.rawValue) }
      guard try FSHeadRow.where({ $0.grp.eq(group.rawValue) && $0.parentPath.eq(path.rawValue) }).fetchCount(db) == 0 else { return false }
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, in: db)
      try LiveFS.tombstone(path: path.rawValue, group: group, rev: rev, op: .delete, in: db)
      return true
    }
  }

  public func currentRevision() async throws -> Int {
    try await writer.read { db in Int(try Substrate.maxRevision(in: db)) }
  }

  public func history(_ path: SpacePath, in group: GroupID, after: Int? = nil, limit: Int? = nil) async throws -> [(Rev, Date, Change)] {
    let path = try await MachineFolders.stored(path, mutating: false, in: runtime)
    return try await writer.read { db in
      let rows = try FSVersionRow
        .where { $0.grp.eq(group.rawValue) && $0.path.eq(path.rawValue) && $0.rev.gt(Int64(after ?? 0)) }
        .order { $0.rev }
        .limit(limit ?? Int.max)
        .join(RevisionRow.all) { $0.rev.eq($1.rev) }
        .select { JournalEntry.Columns(rev: $0.rev, mtime: $1.mtime, op: $0.op, aux: $0.aux) }
        .fetchAll(db)
      return rows.map { row in
        let (rev, mtime, op, aux) = (row.rev, row.mtime, row.op, row.aux)
        let date = (try? SQLiteDateFormat.date(from: mtime)) ?? Date(timeIntervalSince1970: 0)
        let change: Change = switch JournalOp(rawValue: op)! {
        case .write: .write(VersionToken(rev: Int(rev)))
        case .delete: .delete
        case .move: .move(to: aux!)
        case .checkout: .checkout(fromRev: Int(aux!)!)
        }
        return (Rev(Int(rev)), date, change)
      }
    }
  }

  /// The viewer and page behind each of `revs` a page wrote; other revisions are absent.
  public func attributions(of revs: [Rev]) async throws -> [Rev: RevisionAttribution] {
    guard !revs.isEmpty else { return [:] }
    return try await writer.read { db in
      var found: [Rev: RevisionAttribution] = [:]
      let keys = revs.map { Int64($0.value) }
      for start in stride(from: 0, to: keys.count, by: 500) {
        let chunk = Array(keys[start ..< min(start + 500, keys.count)])
        for row in try RevisionActorRow.where({ $0.rev.in(chunk) }).fetchAll(db) {
          found[Rev(Int(row.rev))] = RevisionAttribution(actor: row.actor, via: row.via)
        }
      }
      return found
    }
  }

  public func checkout(_ path: SpacePath, rev target: Rev, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, ifMatch: VersionToken? = nil, createOnly: Bool = false) async throws -> (Rev, VersionToken) {
    let path = try await MachineFolders.stored(path, mutating: true, in: runtime)
    guard !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    if path.isLive, let restored = try await restoredLive(path, rev: target, in: group) {
      if let ifMatch, ifMatch.rev == nil { throw SpaceError.versionMismatch(path.rawValue) }
      let base = ifMatch.map { DocumentBase.current(Int64($0.rev!)) } ?? .latest
      let rev = try await documents.write(
        group, path, restored, base: base, createOnly: createOnly, acting: acting, attribution: attribution,
        checkout: Int64(target.value),
      )
      return (Rev(Int(rev)), VersionToken(rev: Int(rev)))
    }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await blobs.write(writer) { db, cache in
      let ceiling = Int64(target.value)
      guard try Substrate.revisionExists(ceiling, in: db) else { throw SpaceError.invalidRevision(target.value) }
      let resolved = try HistoricalFS.resolve(path.rawValue, group: group, ceiling: ceiling, in: db)
      if let resolved, resolved.kind == "directory" { throw SpaceError.notAFile(path.rawValue) }
      let liveHead = try Substrate.head(path, group: group, in: db)
      if createOnly, liveHead != nil { throw SpaceError.alreadyExists(path.rawValue) }
      try LiveFS.checkIfMatch(ifMatch, head: liveHead, path: path)
      guard resolved != nil || liveHead != nil else { throw SpaceError.notFound(path.rawValue) }
      if let resolved, resolved.kind == "file", let liveHead, liveHead.kind == "file", resolved.blobHash == liveHead.blobHash {
        try self.documents.removed(under: path, in: group, rev: liveHead.rev, on: db)
        return (Rev(Int(liveHead.rev)), VersionToken(rev: Int(liveHead.rev)))
      }
      let newRev = try Substrate.mintRevision(mtime: mtime, group: acting, attribution: attribution, in: db)
      let token = VersionToken(rev: Int(newRev))
      let fromRev = String(target.value)
      switch resolved?.kind {
      case "file":
        if liveHead?.kind == "table" { try Tables.retire(path, group: group, rev: newRev, in: db) }
        let hash = resolved!.blobHash!
        try Substrate.writeFile(
          path, group: group, blob: try cache.blob(of: hash, in: db),
          rev: newRev, mtime: mtime, op: .checkout, aux: fromRev, in: db,
        )
      case "table":
        if liveHead?.kind == "file" { try Induction.remove(path: path, group: group, in: db) }
        try Tables.restore(path, group: group, ceiling: ceiling, rev: newRev, mtime: mtime, in: db)
      default:
        try LiveFS.remove(liveHead!, group: group, rev: newRev, op: .checkout, aux: fromRev, in: db)
      }
      try self.documents.removed(under: path, in: group, rev: newRev, on: db)
      return (Rev(Int(newRev)), token)
    }
  }

  /// The text a live file had at `rev`, which its live node merges in; nil when it had none.
  private func restoredLive(_ path: SpacePath, rev target: Rev, in group: GroupID) async throws -> Data? {
    try await blobs.read(writer) { db, cache in
      let ceiling = Int64(target.value)
      guard try Substrate.revisionExists(ceiling, in: db) else { throw SpaceError.invalidRevision(target.value) }
      guard let resolved = try HistoricalFS.resolve(path.rawValue, group: group, ceiling: ceiling, in: db) else { return nil }
      guard resolved.kind == "file", let hash = resolved.blobHash else { throw SpaceError.notAFile(path.rawValue) }
      return Data(try cache.blob(of: hash, in: db).content)
    }
  }
}
