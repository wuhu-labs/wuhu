#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

@Table("file_document_checkpoint")
struct FileDocumentCheckpointRow: Owned, Sendable {
  var path: String
  var lineage: Int64
  var seq: Int64
  var rev: Int64
}

struct FileDocumentState: Sendable {
  var head: FSHeadRow?
  var checkpoint: FileDocumentCheckpointRow?

  func isCurrent(_ lineage: Int64, seedRev: Int64?) -> Bool {
    if let checkpoint, checkpoint.lineage == lineage { return checkpoint.rev == head?.rev }
    return (checkpoint == nil || checkpoint!.lineage < lineage) && head?.rev == seedRev
  }

  func file() throws -> (rev: Int64, hash: String)? {
    guard let head else { return nil }
    guard head.kind == "file", let hash = head.blobHash else { throw DocumentGone() }
    return (head.rev, hash)
  }
}

struct FileCheckpointCommit: Sendable {
  var rev: Int64
  var seq: Int64
  var previous: Int64
}

extension FilesCell {
  func documentFile(_ path: SpacePath) -> FileDocumentState {
    FileDocumentState(head: file(path), checkpoint: db.rows(FileDocumentCheckpointRow.where { $0.path.eq(path.rawValue) }).first)
  }

  mutating func applyCheckpoint(_ path: SpacePath, hash: String, lineage: Int64, seq: Int64, seedRev: Int64?, attribution: RevisionAttribution?, checkout: Int64?) throws -> FileCheckpointCommit? {
    let state = documentFile(path)
    let previous: Int64
    if let row = state.checkpoint, lineage <= row.lineage {
      guard lineage == row.lineage, state.head?.rev == row.rev else { return nil }
      if seq <= row.seq { return FileCheckpointCommit(rev: row.rev, seq: row.seq, previous: row.seq) }
      previous = row.seq
    } else {
      guard state.head?.rev == seedRev else { return nil }
      previous = 0
    }
    do {
      try requireAncestorDirectories(path)
    } catch SpaceError.notADirectory {
      ctx.send(DocumentCell.ID(group, path)).removed(currentRevision(), lineage: lineage)
      return nil
    }
    let rev: Int64
    if let head = state.head, head.blobHash == hash { rev = head.rev } else {
      let object = Bucket.row(hash, in: db)!
      let mtime = SQLiteDateFormat.string(from: Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000))
      rev = try mintRevision(mtime, attribution: attribution)
      try ensureAncestorDirectories(path, rev: rev, mtime: mtime)
      try appendVersion(path.rawValue, rev: rev, kind: "file", hash: hash, op: checkout == nil ? .write : .checkout, aux: checkout.map(String.init))
      try upsertHead(FSHeadRow(
        grp: id.key,
        path: path.rawValue,
        parentPath: path.parent.rawValue,
        kind: "file",
        blobHash: hash,
        size: object.size,
        lineCount: object.content.map { Substrate.lineCount($0).map(Int64.init) } ?? object.lineCount,
        etag: Substrate.etag(for: hash),
        rev: rev,
        mtime: mtime,
      ))
      try removeIndex(path)
    }
    try db.execute(FileDocumentCheckpointRow.where { $0.path.eq(path.rawValue) }.delete())
    try db.execute(FileDocumentCheckpointRow.insert { FileDocumentCheckpointRow(path: path.rawValue, lineage: lineage, seq: seq, rev: rev) })
    ctx.send(DocumentCell.ID(group, path)).committed(lineage, seq, rev, previous)
    return FileCheckpointCommit(rev: rev, seq: seq, previous: previous)
  }
}
