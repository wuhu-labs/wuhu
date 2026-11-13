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

extension FSHeadRow {
  /// The file or folder whose head is at `path` in `group`.
  static func at(_ path: SpacePath, in group: GroupID) -> Where<FSHeadRow> {
    Self.where { $0.grp.eq(group.rawValue) && $0.path.eq(path.rawValue) }
  }
}

extension DocumentCell {
  struct Checkpoint: Sendable {
    let rev: Int64
    let frontiers: Data
  }

  /// The revision the document's state row says its file has.
  func fileRev() -> Int64? {
    db.rows(DocumentStateRow.all).first?.fileRev
  }

  func lineage() -> Int64? { db.rows(DocumentLineageRow.all).first?.lineage }

  /// Whether the document holds edits its file lacks.
  func dirty() -> Bool {
    if db.rows(DocumentStateRow.all).first?.dirtyAt != nil { return true }
    guard let lineage = db.rows(DocumentLineageRow.all).first else { return false }
    return !db.rows(DocumentPendingCheckpointRow.where { $0.seq.eq(lineage.seq) }).isEmpty
  }

  /// The state row: its history, the file revision it stands at, when it fell behind, and its frontier.
  func state() -> (history: String, fileRev: Int64?, dirtyAt: Int64?, frontier: Data)? {
    db.rows(DocumentStateRow.all).first.map {
      (history: $0.history, fileRev: $0.fileRev, dirtyAt: $0.dirtyAt, frontier: Data($0.frontier))
    }
  }

  /// The checkpoints it holds, oldest revision first.
  func checkpoints() -> [Checkpoint] {
    db.rows(DocumentCheckpointRow.all.order { $0.rev }).map { Checkpoint(rev: $0.rev, frontiers: Data($0.frontiers)) }
  }

  /// How many snapshot rows it holds: at most one, and one whenever it holds a state.
  func snapshotCount() -> Int {
    db.rows(DocumentSnapshotRow.all.asSelect().count()).first!
  }

  func material(_ file: FileDocumentState, base: DocumentBase, createOnly: Bool) throws -> DocumentMaterial {
    if let head = file.head, head.kind != "file" { throw SpaceError.notAFile(path.rawValue) }
    if createOnly, file.head != nil { throw SpaceError.alreadyExists(path.rawValue) }
    if let row = db.rows(DocumentStateRow.all).first, let lineage = db.rows(DocumentLineageRow.all).first,
       file.isCurrent(lineage.lineage, seedRev: lineage.seedRev)
    {
      let snapshot = db.rows(DocumentSnapshotRow.all).first!
      let frontiers = try base.frontiers(path, rev: file.head?.rev, notDocument: row.notDocument) { rev in
        if let checkpoint = db.rows(DocumentCheckpointRow.where { $0.rev.eq(rev) }).first { return Data(checkpoint.frontiers) }
        if let landed = file.checkpoint, landed.lineage == lineage.lineage, landed.rev == rev,
           let pending = db.rows(DocumentPendingCheckpointRow.where { $0.seq.eq(landed.seq) }).first { return Data(pending.frontiers) }
        throw SpaceError.versionMismatch(path.rawValue)
      }
      return DocumentMaterial(
        history: row.history,
        fileRev: file.head?.rev,
        snapshot: Data(snapshot.snapshot),
        updates: db.rows(DocumentLogRow.all.order { $0.seq }).map { Data($0.bytes) },
        base: frontiers,
        notDocument: row.notDocument,
      )
    }
    guard let head = file.head else { return DocumentMaterial() }
    return DocumentMaterial(fileRev: head.rev, hash: head.blobHash!)
  }
}
