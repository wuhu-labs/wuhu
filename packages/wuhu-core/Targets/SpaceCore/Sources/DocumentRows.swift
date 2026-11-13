#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite
import WuweiQueries

/// A move's transaction found a document at or under its source holding edits its file lacks.
struct DocumentEdited: Error {}

/// The host's side of the documents: the files their cells write in a step through the host's own
/// connection, and the bytes only the host can reach for a document whose file lives in the object
/// store. Everything read about a document itself is the document cell's.
struct DocumentRows: Sendable {
  let writer: any DatabaseWriter
  let bucket: Bucket

  // MARK: A step's work, on the connection the step writes on

  /// The file's revision and blob at `path`; `DocumentGone` when what is there is no file of ours.
  /// A failing disk traps, as it does behind a cell's own `db.execute`.
  static func head(_ path: SpacePath, _ group: GroupID, in host: AnyObject) throws -> (rev: Int64, hash: String)? {
    let db = host as! GRDB.Database
    guard let head = try! Substrate.head(path, group: group, in: db) else { return nil }
    guard head.kind == "file", let hash = head.blobHash else { throw DocumentGone() }
    return (head.rev, hash)
  }

  /// Writes `text` as the file in the step's transaction, one revision, and answers the revision the
  /// head now holds — its own when the bytes are already there. `DocumentGone` when the head is not
  /// the revision the document built on.
  @discardableResult
  static func commit(
    _ path: SpacePath, _ group: GroupID, acting: GroupID, attribution: RevisionAttribution?, blob: Blob, expecting: Int64?,
    checkout: Int64?, mtime: String, in host: AnyObject,
  ) throws -> Int64 {
    let db = host as! GRDB.Database
    let head = try! Substrate.head(path, group: group, in: db)
    guard head?.rev == expecting else { throw DocumentGone() }
    let outcome: FSWriteOutcome
    do {
      outcome = try LiveFS.commitFile(
        path, group: group, acting: acting, attribution: attribution, blob: blob, head: head, mtime: mtime,
        op: checkout == nil ? .write : .checkout, aux: checkout.map(String.init), in: db,
      )
    } catch SpaceError.pathIsDirectory(_) {
      throw DocumentGone()
    } catch let SpaceError.notADirectory(dir) {
      throw SpaceError.notADirectory(dir)
    } catch {
      preconditionFailure("the file's commit failed on storage: \(error)")
    }
    switch outcome {
    case let .unchanged(rev), let .wrote(rev): return rev
    }
  }

  /// Refuses a move whose source holds a document with edits its file lacks, in the transaction that
  /// would carry the old bytes: one writer serializes the check with the move, so nothing can be
  /// acknowledged in between.
  static func requireCommitted(_ group: GroupID, under path: SpacePath, in db: GRDB.Database) throws {
    guard try Self.dirtyKeys(group, under: path, in: db).isEmpty else { throw DocumentEdited() }
  }

  // MARK: The bytes only the host can reach

  /// The bytes of a file, inline or in the object store.
  func text(of hash: String) async throws -> Data {
    Data(try await bucket.bytes(hash))
  }

  /// The document as a merge takes it. One read, because the state, snapshot, log and checkpoint it
  /// answers with must agree, and a read handle runs each statement on a snapshot of its own.
  func material(_ group: GroupID, _ path: SpacePath, base: DocumentBase, createOnly: Bool) async throws -> DocumentMaterial {
    let key = DocumentCell.key(group, path)
    var material = try await writer.read { db -> DocumentMaterial in
      let head = try Substrate.head(path, group: group, in: db)
      if let head, head.kind != "file" { throw SpaceError.notAFile(path.rawValue) }
      if createOnly, head != nil { throw SpaceError.alreadyExists(path.rawValue) }
      if let state = try DocumentStateRow.unscoped.where({ _ in #sql("owner", as: String.self).eq(key) }).fetchOne(db),
         state.fileRev == head?.rev
      {
        let snapshot = try DocumentSnapshotRow.unscoped.where { _ in #sql("owner", as: String.self).eq(key) }.fetchOne(db)
        precondition(snapshot != nil, "a document state has a snapshot")
        let updates = try DocumentLogRow.unscoped.where { _ in #sql("owner", as: String.self).eq(key) }
          .order { $0.seq }.fetchAll(db)
        let frontiers = try base.frontiers(path, rev: state.fileRev, notDocument: state.notDocument) { rev in
          guard let checkpoint = try DocumentCheckpointRow.unscoped.where({
            #sql("owner", as: String.self).eq(key) && $0.rev.eq(rev)
          }).fetchOne(db) else { throw SpaceError.versionMismatch(path.rawValue) }
          return Data(checkpoint.frontiers)
        }
        return DocumentMaterial(
          history: state.history, fileRev: state.fileRev, snapshot: Data(snapshot!.snapshot),
          updates: updates.map { Data($0.bytes) }, base: frontiers, notDocument: state.notDocument,
        )
      }
      guard let head else { return DocumentMaterial() }
      return DocumentMaterial(fileRev: head.rev, hash: head.blobHash!)
    }
    if let hash = material.hash { material.text = try await text(of: hash) }
    return material
  }

  /// The documents at `path` and under it — never a sibling whose name starts the same way (`/notes` must
  /// not reach `/notes-old.wmd` or `/notes0.wmd`). A root reaches every document of its group. The range
  /// below the path starts at `path + "/"` and ends where that prefix's last character is raised by one
  /// (`/` is followed by `0`), so `/notes/plan.wmd` sorts inside it.
  static func range(
    _ group: GroupID, _ path: SpacePath,
  ) -> (exact: String, below: String, belowUpper: String) {
    let exact = group.rawValue + path.rawValue
    let below = path.isRoot ? group.rawValue + "/" : exact + "/"
    var upper = Array(below.unicodeScalars)
    upper[upper.count - 1] = Unicode.Scalar(upper[upper.count - 1].value + 1)!
    return (exact, below, String(String.UnicodeScalarView(upper)))
  }

  private static func dirtyKeys(
    _ group: GroupID, under path: SpacePath, in db: GRDB.Database,
  ) throws -> [String] {
    let range = range(group, path)
    return try DocumentStateRow.unscoped.where {
      (#sql("owner", as: String.self).eq(range.exact) ||
        (#sql("owner", as: String.self).gte(range.below) && #sql("owner", as: String.self).lt(range.belowUpper))) && $0.dirtyAt.isNot(nil)
    }.select { _ in #sql("owner", as: String.self) }.fetchAll(db)
  }
}
