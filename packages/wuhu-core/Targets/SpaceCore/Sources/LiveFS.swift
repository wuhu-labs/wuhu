import Dependencies
import Foundation
import GRDB
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

enum FSWriteOutcome {
  case unchanged(Int64)
  case wrote(Int64)
}

struct LiveFS: SpaceVFS {
  let group: GroupID
  /// The group a mutation's revision is recorded for: the actor's, which a
  /// write into another group it reads is not.
  let acting: GroupID
  let writer: any DatabaseWriter
  let blobs: BlobStore
  let broadcast: FSBroadcast
  let dateGen: DateGenerator
  var listingLimit: Int?
  var listingByteLimit: Int?
  var attribution: RevisionAttribution?

  func read(_ path: String) async throws -> (VersionToken, Data) {
    let p = try Self.validated(path)
    let group = group
    return try await blobs.read(writer) { db, cache in
      guard let head = try Substrate.head(p, group: group, in: db) else { throw SpaceError.notFound(p.rawValue) }
      guard head.kind == "file", let hash = head.blobHash else { throw SpaceError.notAFile(p.rawValue) }
      return (VersionToken(rev: Int(head.rev)), Data(try cache.blob(of: hash, in: db).content))
    }
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    try await write(path, data, ifMatch: ifMatch, createOnly: false)
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?, createOnly: Bool) async throws -> VersionToken {
    let p = try Self.validatedFileTarget(path)
    let blob = try await blobs.stage(Array(data))
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let (group, acting, attribution) = (group, acting, attribution)
    let outcome: FSWriteOutcome = try await writer.write { db in
      let head = try Substrate.head(p, group: group, in: db)
      if createOnly, head != nil { throw SpaceError.alreadyExists(p.rawValue) }
      try Self.checkIfMatch(ifMatch, head: head, path: p)
      return try Self.commitFile(
        p, group: group, acting: acting, attribution: attribution, blob: blob, head: head, mtime: mtime, in: db,
      )
    }
    switch outcome {
    case let .unchanged(rev):
      return VersionToken(rev: Int(rev))
    case let .wrote(rev):
      broadcast.emit(MutationEvent(group: group, path: p.rawValue, rev: Int(rev), kind: .write, entry: .file))
      return VersionToken(rev: Int(rev))
    }
  }

  static func validatedFileTarget(_ path: String) throws -> SpacePath {
    let p = try validated(path, mutating: true)
    guard p.lastComponent?.hasSuffix(".table") != true else { throw SpaceError.reservedTablePath(p.rawValue) }
    return p
  }

  static func commitFile(
    _ p: SpacePath, group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, blob: Blob, head: FSHeadRow?,
    mtime: String, in db: Database,
  ) throws -> FSWriteOutcome {
    if let head, head.kind == "directory" { throw SpaceError.pathIsDirectory(p.rawValue) }
    if let head, head.blobHash == blob.hash { return .unchanged(head.rev) }
    let rev = try Substrate.mintRevision(mtime: mtime, group: acting, attribution: attribution, in: db)
    try Substrate.writeFile(p, group: group, blob: blob, rev: rev, mtime: mtime, in: db)
    return .wrote(rev)
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    let p = try Self.validated(path, mutating: true)
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let (group, acting, attribution) = (group, acting, attribution)
    let (rev, removed): (Int64, [String]) = try await writer.write { db in
      guard let head = try Substrate.head(p, group: group, in: db) else { throw SpaceError.notFound(p.rawValue) }
      try Self.checkIfMatch(ifMatch, head: head, path: p)
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, attribution: attribution, in: db)
      let targets = head.kind == "directory" ? try Substrate.descendantHeads(of: p, group: group, in: db) : [head]
      for node in targets {
        try Self.remove(node, group: group, rev: rev, op: .delete, in: db)
      }
      return (rev, targets.map(\.path))
    }
    for removedPath in removed {
      broadcast.emit(MutationEvent(group: group, path: removedPath, rev: Int(rev), kind: .delete, entry: nil))
    }
  }

  func move(_ path: String, to destination: String) async throws {
    try await move(path, to: destination, replacing: false)
  }

  func move(_ path: String, to destination: String, replacing: Bool) async throws {
    try await move(path, to: destination, in: group, replacing: replacing)
  }

  /// Within one group a move journals a move; across groups it is a delete in
  /// this group and a create in `destinationGroup`, still one revision.
  func move(_ path: String, to destination: String, in destinationGroup: GroupID, replacing: Bool) async throws {
    let src = try Self.validated(path, mutating: true)
    let dst = try Self.validated(destination, mutating: true)
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let (group, acting, attribution) = (group, acting, attribution)
    let across = destinationGroup != group
    let (rev, moved): (Int64, [(from: String, to: String, entry: Entry.Kind)]) = try await blobs.write(
      writer,
      prefetching: { db in
        guard let head = try Substrate.head(src, group: group, in: db) else { return [] }
        let nodes = head.kind == "directory" ? try Substrate.descendantHeads(of: src, group: group, in: db) : [head]
        return nodes.compactMap { $0.kind == "file" ? $0.blobHash : nil }
      },
    ) { db, cache in
      guard let head = try Substrate.head(src, group: group, in: db) else { throw SpaceError.notFound(src.rawValue) }
      if let existing = try Substrate.head(dst, group: destinationGroup, in: db) {
        guard replacing, existing.kind == "file", across || dst != src else { throw SpaceError.alreadyExists(dst.rawValue) }
      }
      if (dst.lastComponent?.hasSuffix(".table") == true) != (head.kind == "table") {
        throw SpaceError.reservedTablePath(dst.rawValue)
      }
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, attribution: attribution, in: db)
      if try Substrate.head(dst, group: destinationGroup, in: db) != nil {
        try Self.tombstone(path: dst.rawValue, group: destinationGroup, rev: rev, op: .delete, in: db)
      }
      try Substrate.ensureAncestorDirectories(dst, group: destinationGroup, rev: rev, mtime: mtime, in: db)
      let nodes = head.kind == "directory" ? try Substrate.descendantHeads(of: src, group: group, in: db) : [head]
      var pairs: [(from: String, to: String, entry: Entry.Kind)] = []
      for node in nodes {
        let newPath = try Self.reparent(node.path, from: src, to: dst)
        if node.kind == "table" {
          try Tables.reparent(
            from: try SpacePath(validating: node.path), in: group, to: newPath, in: destinationGroup, rev: rev, in: db,
          )
        }
        if across {
          try Self.tombstone(path: node.path, group: group, rev: rev, op: .delete, in: db)
        } else {
          try Self.tombstone(path: node.path, group: group, rev: rev, op: .move, aux: newPath.rawValue, in: db)
        }
        try Substrate.appendVersion(
          group: destinationGroup, path: newPath.rawValue, rev: rev, kind: node.kind, blobHash: node.blobHash, op: .write, in: db,
        )
        try Substrate.upsertHead(
          FSHeadRow(
            grp: destinationGroup.rawValue, path: newPath.rawValue, parentPath: newPath.parent.rawValue, kind: node.kind,
            blobHash: node.blobHash, size: node.size, lineCount: node.lineCount,
            etag: node.etag, rev: rev, mtime: mtime,
          ),
          in: db,
        )
        if node.kind == "file", let hash = node.blobHash {
          try Induction.index(path: newPath, group: destinationGroup, content: try cache.blob(of: hash, in: db).content, in: db)
        }
        pairs.append((node.path, newPath.rawValue, Substrate.entryKind(node.kind)))
      }
      return (rev, pairs)
    }
    for pair in moved {
      if across {
        broadcast.emit(MutationEvent(group: group, path: pair.from, rev: Int(rev), kind: .delete, entry: nil))
        broadcast.emit(MutationEvent(group: destinationGroup, path: pair.to, rev: Int(rev), kind: .write, entry: pair.entry))
      } else {
        broadcast.emit(MutationEvent(group: group, path: pair.to, from: pair.from, rev: Int(rev), kind: .move, entry: pair.entry))
      }
    }
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    let p = try Self.validated(path)
    let group = group
    return try await writer.read { db in
      if !p.isRoot {
        guard let head = try Substrate.head(p, group: group, in: db) else { throw SpaceError.notFound(p.rawValue) }
        guard head.kind == "directory" else { throw SpaceError.notADirectory(p.rawValue) }
      }
      let query = FSHeadRow.where { $0.grp.eq(group.rawValue) && $0.parentPath.eq(p.rawValue) }
        .order { $0.path }.limit(listingLimit ?? Int.max)
      let cursor = try QueryValueCursor<FSHeadRow>(db: db, query: query.query)
      var budget = ListingBudget(limit: listingByteLimit)
      var entries: [Entry] = []
      while let child = try cursor.next() {
        let name = SpacePath.lastComponent(of: child.path)
        try budget.consume(name)
        entries.append(Substrate.entry(from: child))
      }
      let token = VersionToken(rev: Int(try Substrate.maxRevision(in: db)))
      return (token, entries.sorted { $0.name < $1.name })
    }
  }

  func stat(_ path: String) async throws -> Entry {
    let p = try Self.validated(path)
    let group = group
    return try await writer.read { db in
      guard let head = try Substrate.head(p, group: group, in: db) else { throw SpaceError.notFound(p.rawValue) }
      return Substrate.entry(from: head)
    }
  }

  static func validated(_ path: String, mutating: Bool = false) throws -> SpacePath {
    let p: SpacePath
    do { p = try SpacePath(validating: path) } catch { throw SpaceError.notFound(path) }
    if mutating, p.isReserved { throw SpaceError.alreadyExists(p.rawValue) }
    return p
  }

  static func checkIfMatch(_ ifMatch: VersionToken?, head: FSHeadRow?, path: SpacePath) throws {
    guard let ifMatch else { return }
    guard let head, let expected = ifMatch.rev, Int(head.rev) == expected else {
      throw SpaceError.versionMismatch(path.rawValue)
    }
  }

  static func remove(_ node: FSHeadRow, group: GroupID, rev: Int64, op: JournalOp, aux: String? = nil, in db: Database) throws {
    if node.kind == "table" {
      try Tables.retire(try SpacePath(validating: node.path), group: group, rev: rev, in: db)
    }
    try tombstone(path: node.path, group: group, rev: rev, op: op, aux: aux, in: db)
  }

  static func tombstone(path: String, group: GroupID, rev: Int64, op: JournalOp, aux: String? = nil, in db: Database) throws {
    try Substrate.appendVersion(group: group, path: path, rev: rev, kind: nil, blobHash: nil, op: op, aux: aux, in: db)
    try db.execute(sql: "DELETE FROM fs_heads WHERE grp = ? AND path = ?", arguments: [group.rawValue, path])
    if let p = try? SpacePath(validating: path) { try Induction.remove(path: p, group: group, in: db) }
  }

  static func reparent(_ path: String, from src: SpacePath, to dst: SpacePath) throws -> SpacePath {
    if path == src.rawValue { return dst }
    let suffix = path.dropFirst(src.rawValue.count)
    return try SpacePath(validating: dst.rawValue + suffix)
  }
}
