#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import KeelObjectStore
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

// What a host action asks of a document that one statement answers: its file, its state row and when
// it fell behind. What a merge needs of the state, snapshot, log and checkpoints together is a host
// read (`DocumentRows.material`), because those must agree and a read handle is a snapshot per
// statement. The file store's own reads stay in `Substrate`, so the two queries over `fs_heads` and
// the blobs are kept in both places.
extension DocumentCell {
  struct Checkpoint: Sendable {
    let rev: Int64
    let frontiers: Data
  }

  /// The file's revision and hash, with its text when the bytes are inline; nil when the file is gone.
  func file() throws -> (rev: Int64, text: Data?, hash: String)? {
    guard let head = db.rows(FSHeadRow.at(path, in: group)).first else { return nil }
    guard head.kind == "file", let hash = head.blobHash else { throw SpaceError.notAFile(path.rawValue) }
    switch try storedBlob(hash) {
    case let .inline(content): return (head.rev, Data(content), hash)
    case .external: return (head.rev, nil, hash)
    }
  }

  /// The revision the document's state row says its file has.
  func fileRev() -> Int64? {
    db.rows(DocumentStateRow.all).first?.fileRev
  }

  /// Whether the document holds edits its file lacks.
  func dirty() -> Bool {
    db.rows(DocumentStateRow.all).first?.dirtyAt != nil
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

  private func storedBlob(_ hash: String) throws -> StoredBlob {
    if let key = db.rows(BlobObjectRow.where { $0.hash.eq(hash) }.select(\.objectKey)).first {
      return .external(try ObjectKey(key))
    }
    guard let content = db.rows(BlobRow.where { $0.hash.eq(hash) }.select(\.content)).first else {
      throw SpaceError.notFound(hash)
    }
    return .inline(content)
  }
}
