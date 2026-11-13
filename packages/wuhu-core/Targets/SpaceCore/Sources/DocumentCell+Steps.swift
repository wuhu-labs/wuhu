#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LiveDocument
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

extension DocumentCell {
  // MARK: The document a step works on

  struct Document {
    var history: String
    var lineage: Int64
    /// The latest checkpoint revision acknowledged by FilesCell.
    var fileRev: Int64?
    /// What the snapshot and the log hold; nil while no row is stored.
    var frontier: Data?
    var nextSeq: Int64
    /// When the file last fell behind a changed frame; nil while it is current.
    var dirtyAt: Int64?
    var snapshot: [UInt8]
    /// Why the file's text is no document.
    var notDocument: String?
  }

  /// The document a client's frames continue: its rows, which must still be its file's.
  func withCurrentDocument<T>(_ file: FileDocumentState, _ body: (inout DocumentCell, inout Document, LiveReplica) throws -> T) throws -> T {
    let replicas = documents.replicas
    return try replicas.with(id.key) { slot in
      guard var document = try storedDocument(file).document else { throw DocumentGone() }
      let replica = slot.take(document.frontier) { rebuild(document) }
      var cell = self
      let value = try body(&cell, &document, replica)
      slot.keep(document.frontier)
      return value
    }
  }

  /// The document an attach or an agent's write works on, seeded from its file when its rows are
  /// absent or older: a file that is a document opens a history of its own at its revision, one that
  /// is not opens none.
  func withOpenDocument<T>(
    file: FileDocumentState, existing: Bool, keeping keep: Int?, _ body: (inout DocumentCell, inout Document, LiveReplica) throws -> T,
  ) throws -> T {
    let replicas = documents.replicas
    return try replicas.with(id.key) { slot in
      var cell = self
      let stored = try storedDocument(file)
      if var document = stored.document {
        let replica = slot.take(document.frontier) { rebuild(document) }
        let value = try body(&cell, &document, replica)
        slot.keep(document.frontier)
        return value
      }
      let head = try file.file()
      if stored.stored {
        let others = sockets().filter { $0.id != keep }
        for socket in others {
          refuse(socket, LiveRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted"))
        }
      }
      guard head != nil || !existing else {
        throw LiveRefusal(code: .notFound, message: "\(path.rawValue) does not exist")
      }
      var (document, replica) = try cell.seeded(head, nil)
      slot.put(replica, document.frontier)
      let value = try body(&cell, &document, replica)
      slot.keep(document.frontier)
      return value
    }
  }

  /// The stored document, and when it matches its file, the document itself.
  func storedDocument(_ file: FileDocumentState) throws -> (document: Document?, stored: Bool) {
    guard let row = db.rows(DocumentStateRow.all).first else { return (nil, false) }
    guard let snapshot = db.rows(DocumentSnapshotRow.all).first else {
      preconditionFailure("\(id.key) holds state without a snapshot")
    }
    let document = Document(
      history: row.history, lineage: db.rows(DocumentLineageRow.all).first!.lineage, fileRev: row.fileRev, frontier: Data(row.frontier), nextSeq: row.nextSeq, dirtyAt: row.dirtyAt,
      snapshot: snapshot.snapshot, notDocument: row.notDocument,
    )
    let lineage = db.rows(DocumentLineageRow.all).first!
    return (file.isCurrent(lineage.lineage, seedRev: lineage.seedRev) ? document : nil, true)
  }

  func rebuild(_ document: Document) -> LiveReplica {
    let log = db.rows(DocumentLogRow.all.order { $0.seq })
    do throws(LiveError) {
      return try LiveReplica(format, snapshot: Data(document.snapshot), updates: log.map { Data($0.bytes) })
    } catch {
      preconditionFailure("\(id.key) cannot rebuild from its own rows: \(error)")
    }
  }

  /// The document a file's text makes, or a new empty lineage when no file exists. `text` is the bytes a host
  /// fetched because they are not inline; a file whose bytes are not inline and were not handed in is one
  /// the cell cannot open now. Every start of a history clears what the path held.
  mutating func seeded(_ head: (rev: Int64, hash: String)?, _ text: Data?) throws -> (Document, LiveReplica) {
    let replica = LiveReplica(format)
    var document = Document(history: UUID().uuidString, lineage: 0, fileRev: head?.rev, frontier: nil, nextSeq: 1, dirtyAt: nil, snapshot: [], notDocument: nil)
    guard let head else {
      document.frontier = replica.frontiers
      document.snapshot = Array(try! replica.snapshot())
      try writeSeed(&document, replica)
      return (document, replica)
    }
    let inline: Data? = switch try Bucket.stored(head.hash, in: db) {
    case let .inline(content): Data(content)
    case .external: nil
    }
    guard let bytes = inline ?? text else { throw DocumentGone() }
    do {
      guard let string = String(validating: bytes, as: UTF8.self) else {
        throw SpaceError.liveSyntax(path: path.rawValue, line: nil, reason: notUTF8)
      }
      if let merged = try replica.merge(text: string, base: nil, peer: documents.peer(), restoring: true) {
        try replica.importUpdate(merged.update)
      }
    } catch let SpaceError.liveSyntax(_, line, reason) {
      document.notDocument = line.map { "line \($0): \(reason)" } ?? reason
    } catch let error as LiveError {
      guard case let .syntax(syntax) = error else { preconditionFailure("a seed of our own text failed: \(error)") }
      document.notDocument = "line \(syntax.line): \(syntax.reason)"
    }
    document.frontier = replica.frontiers
    document.snapshot = Array(try! replica.snapshot())
    try writeSeed(&document, replica)
    return (document, replica)
  }

  mutating func writeSeed(_ document: inout Document, _ replica: LiveReplica) throws {
    let lineage = (db.rows(DocumentLineageRow.all).first?.lineage ?? 0) + 1
    document.lineage = lineage
    try clear()
    try db.execute(DocumentLineageRow.delete())
    try db.execute(DocumentLineageRow.insert { DocumentLineageRow(lineage: lineage, seq: 0, seedRev: document.fileRev) })
    try db.execute(
      DocumentStateRow.insert {
        DocumentStateRow(
          history: document.history, fileRev: document.fileRev, frontier: Array(replica.frontiers), nextSeq: document.nextSeq, dirtyAt: nil,
          notDocument: document.notDocument,
        )
      },
    )
    try saveSnapshot(document.snapshot)
    if document.notDocument == nil, let rev = document.fileRev {
      try db.execute(DocumentCheckpointRow.insert { DocumentCheckpointRow(rev: rev, frontiers: Array(replica.frontiers)) })
    }
  }

  mutating func clear() throws {
    try db.execute(DocumentStateRow.delete())
    try db.execute(DocumentSnapshotRow.delete())
    try db.execute(DocumentLogRow.delete())
    try db.execute(DocumentCheckpointRow.delete())
    try db.execute(DocumentPendingCheckpointRow.delete())
  }

  mutating func saveSnapshot(_ snapshot: [UInt8]) throws {
    try db.execute(DocumentSnapshotRow.delete())
    try db.execute(DocumentSnapshotRow.insert { DocumentSnapshotRow(snapshot: snapshot) })
  }

  // MARK: Steps

  /// A changed frame: one log row and the state it moved — never the snapshot, which is its own row so
  /// this update rewrites a page instead of the blob.
  mutating func append(_ document: inout Document, _ replica: LiveReplica, _ bytes: [UInt8]) throws {
    let seq = document.nextSeq
    document.nextSeq += 1
    document.dirtyAt = ctx.now.milliseconds
    document.frontier = replica.frontiers
    try db.execute(DocumentLogRow.insert { DocumentLogRow(seq: seq, bytes: bytes) })
    try db.execute(
      DocumentStateRow.update {
        $0.frontier = #bind(Array(replica.frontiers))
        $0.nextSeq = #bind(document.nextSeq)
        $0.dirtyAt = #bind(document.dirtyAt)
      },
    )
  }

  /// The log into the snapshot: no revision, no file write, only what a later rebuild imports.
  mutating func fold(_ document: inout Document, _ replica: LiveReplica) throws {
    let snapshot = Array(try! replica.snapshot())
    document.snapshot = snapshot
    document.frontier = replica.frontiers
    try saveSnapshot(snapshot)
    try db.execute(DocumentStateRow.update { $0.frontier = #bind(Array(replica.frontiers)) })
    try db.execute(DocumentLogRow.where { $0.seq.lt(document.nextSeq) }.delete())
  }

  func pendingUpdates() -> Int {
    db.rows(DocumentLogRow.all.asSelect().count()).first!
  }

  @discardableResult
  mutating func commit(
    _ document: inout Document, _ replica: LiveReplica, acting: GroupID, attribution: RevisionAttribution?, checkout: Int64? = nil,
    relaying update: Data? = nil,
  ) throws -> DocumentCheckpoint {
    let snapshot = Array(try! replica.snapshot()), content = Array(replica.text.utf8)
    let blob = Blob(hash: Substrate.blobHash(content), content: content, externalKey: nil)
    try Bucket.put(blob, in: &db)
    let lineage = db.rows(DocumentLineageRow.all).first!, seq = lineage.seq + 1
    try db.execute(DocumentLineageRow.update { $0.seq = #bind(seq) })
    try db.execute(DocumentPendingCheckpointRow.insert { DocumentPendingCheckpointRow(seq: seq, frontiers: Array(replica.frontiers)) })
    document.frontier = replica.frontiers; document.snapshot = snapshot; document.dirtyAt = nil; document.notDocument = nil
    try db.execute(DocumentLogRow.delete())
    try db.execute(DocumentStateRow.update {
      $0.frontier = #bind(Array(replica.frontiers)); $0.nextSeq = #bind(document.nextSeq); $0.dirtyAt = #bind(nil); $0.notDocument = #bind(nil)
    })
    try saveSnapshot(snapshot)
    ctx.send(FilesCell.ID(group.rawValue)).checkpoint(path.rawValue, hash: blob.hash, lineage: lineage.lineage, seq: seq, seedRev: lineage.seedRev, attribution: attribution, checkout: checkout)
    if let update { send(.frame(.update(Array(update)))) }
    return DocumentCheckpoint(hash: blob.hash, lineage: lineage.lineage, seq: seq, seedRev: lineage.seedRev)
  }

  mutating func prepareCheckpoint() -> DocumentCheckpoint? {
    do {
      let file = ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)
      return try withCurrentDocument(file) { cell, document, replica in
        if document.dirtyAt != nil { return try cell.commit(&document, replica, acting: cell.group, attribution: nil) }
        let lineage = cell.db.rows(DocumentLineageRow.all).first!
        guard !cell.db.rows(DocumentPendingCheckpointRow.where { $0.seq.eq(lineage.seq) }).isEmpty else { return nil }
        return DocumentCheckpoint(hash: Substrate.blobHash(Array(replica.text.utf8)), lineage: lineage.lineage, seq: lineage.seq, seedRev: lineage.seedRev)
      }
    } catch is DocumentGone { settleGone(); return nil } catch {
      preconditionFailure("a checkpoint threw what a checkpoint does not: \(error)")
    }
  }

  /// A step found the file gone: the edits are moot, so nothing stays due (a wake that finds nothing due
  /// would trap), and the connections close; the rows themselves go only by `removed(at:)`.
  mutating func settleGone() {
    try! db.execute(DocumentStateRow.update { $0.dirtyAt = #bind(nil) })
    for socket in sockets() {
      socket.send(.control(.error(code: .notFound, message: "\(path.rawValue) was moved or deleted")))
      socket.close()
    }
  }

  /// The sockets and the rows of a document whose file is gone: the next touch of its path starts over.
  mutating func drop() {
    for socket in sockets() {
      socket.send(.control(.error(code: .notFound, message: "\(path.rawValue) was moved or deleted")))
      socket.close()
    }
    try! clear()
    documents.replicas.drop(id.key)
  }
}
