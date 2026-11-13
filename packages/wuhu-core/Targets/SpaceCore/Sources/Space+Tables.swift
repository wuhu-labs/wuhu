#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  public func createTable(_ path: SpacePath, header: TableHeader, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil) async throws -> Rev {
    guard path.lastComponent?.hasSuffix(".table") == true else { throw SpaceError.notATable(path.rawValue) }
    let path = try await MachineFolders.stored(path, mutating: true, in: runtime)
    guard !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await Rev(Int(worker.call(FilesCell.ID(group.rawValue)) { try $0.createTable(path, header: header, mtime: mtime, attribution: attribution) }))
  }

  public func alterTable(_ path: SpacePath, header: TableHeader, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, ifMatch: VersionToken? = nil, allowDropColumns: Bool = true) async throws -> Rev {
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await Rev(Int(worker.call(FilesCell.ID(group.rawValue)) {
      try $0.alterTable(path, header: header, ifMatch: ifMatch, allowDropColumns: allowDropColumns, mtime: mtime, attribution: attribution)
    }))
  }

  public func tableSchema(_ path: SpacePath, in group: GroupID, rev: Rev? = nil) async throws -> (header: TableHeader, token: VersionToken) {
    try worker.cell(FilesCell.ID(group.rawValue)).tableSchema(path, at: rev.map { Int64($0.value) })
  }

  public func mutateRows(_ path: SpacePath, _ ops: [RowOp], in group: GroupID, acting: GroupID) async throws -> Rev {
    try await commitRows(path, ops, in: group, acting: acting).rev
  }

  public func commitRows(_ path: SpacePath, _ ops: [RowOp], in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil) async throws -> RowCommit {
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await worker.call(FilesCell.ID(group.rawValue)) { try $0.commitRows(path, ops: ops, mtime: mtime, attribution: attribution) }
  }

  public func commitRows(_ path: SpacePath, edits: [RowEdit], in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil) async throws -> RowCommit {
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await worker.call(FilesCell.ID(group.rawValue)) { try $0.commitRows(path, edits: edits, mtime: mtime, attribution: attribution) }
  }
}
