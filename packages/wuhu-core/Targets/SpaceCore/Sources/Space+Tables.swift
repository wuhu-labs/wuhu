import Foundation
import GRDB
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  public func createTable(_ path: SpacePath, header: TableHeader, in group: GroupID, acting: GroupID) async throws -> Rev {
    guard path.lastComponent?.hasSuffix(".table") == true else { throw SpaceError.notATable(path.rawValue) }
    guard !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let rev = try await writer.write { db in
      try MachineFolders.requireStored(path, in: db)
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, in: db)
      try Tables.create(path, group: group, header: header, rev: rev, mtime: mtime, in: db)
      return Rev(Int(rev))
    }
    broadcast.emit(MutationEvent(group: group, path: path.rawValue, rev: rev.value, kind: .write, entry: .table))
    return rev
  }

  public func alterTable(_ path: SpacePath, header: TableHeader, in group: GroupID, acting: GroupID) async throws -> Rev {
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let rev = try await writer.write { db in
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, in: db)
      try Tables.alter(path, group: group, header: header, rev: rev, mtime: mtime, in: db)
      return Rev(Int(rev))
    }
    broadcast.emit(MutationEvent(group: group, path: path.rawValue, rev: rev.value, kind: .write, entry: .table))
    return rev
  }

  public func mutateRows(_ path: SpacePath, _ ops: [RowOp], in group: GroupID, acting: GroupID) async throws -> Rev {
    try await commitRows(path, ops, in: group, acting: acting).rev
  }

  /// Positional row ops in one revision; the commit carries the inserted ids.
  public func commitRows(
    _ path: SpacePath, _ ops: [RowOp], in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil,
  ) async throws -> RowCommit {
    try await commitRows(path, in: group, acting: acting, attribution: attribution) { _, _ in ops }
  }

  /// Named-field row ops in one revision. Each value is checked against its
  /// column's type; an update keeps the fields it does not name.
  public func commitRows(
    _ path: SpacePath, edits: [RowEdit], in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil,
  ) async throws -> RowCommit {
    try await commitRows(path, in: group, acting: acting, attribution: attribution) { header, db in
      try edits.map { edit in
        switch edit {
        case let .insert(fields):
          return .insert(try Cells.positional(fields, header: header, base: nil, path: path))
        case let .update(id, fields):
          let base = try Tables.openPayload(path, group: group, id: id, in: db)
          return .update(id: id, try Cells.positional(fields, header: header, base: base, path: path))
        case let .delete(id):
          return .delete(id: id)
        }
      }
    }
  }

  private func commitRows(
    _ path: SpacePath, in group: GroupID, acting: GroupID, attribution: RevisionAttribution?,
    ops: @escaping @Sendable (TableHeader, Database) throws -> [RowOp],
  ) async throws -> RowCommit {
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let commit = try await writer.write { db in
      let header = try Tables.currentHeader(path, group: group, in: db)
      let resolved = try ops(header, db)
      let rev = try Substrate.mintRevision(mtime: mtime, group: acting, attribution: attribution, in: db)
      var ids: [Int64] = []
      for op in resolved {
        switch op {
        case let .insert(cells):
          ids.append(try Tables.insertRow(path, group: group, header: header, cells: cells, rev: rev, in: db))
        case let .update(id, cells):
          try Tables.updateRow(path, group: group, header: header, id: id, cells: cells, rev: rev, in: db)
        case let .delete(id):
          try Tables.deleteRow(path, group: group, id: id, rev: rev, in: db)
        }
      }
      try Substrate.touchTableNode(path, group: group, rev: rev, mtime: mtime, in: db)
      return RowCommit(rev: Rev(Int(rev)), ids: ids)
    }
    broadcast.emit(MutationEvent(group: group, path: path.rawValue, rev: commit.rev.value, kind: .write, entry: .table))
    return commit
  }
}
