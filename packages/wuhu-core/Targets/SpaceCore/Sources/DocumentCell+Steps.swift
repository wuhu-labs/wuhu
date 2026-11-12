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

// The steps behind `DocumentCell`: the rows a step loads, the replica it rebuilds, and the writes
// that keep the file one revision behind the frames.
extension DocumentCell {
  // MARK: The document a step works on

  struct Document {
    var history: String
    /// The revision of the file its snapshot stands for; nil while there is no file.
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
  func withCurrentDocument<T>(_ body: (inout DocumentCell, inout Document, LiveReplica) throws -> T) throws -> T {
    let replicas = documents.replicas
    return try replicas.with(id.key) { slot in
      guard var document = try storedDocument().document else { throw DocumentGone() }
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
    existing: Bool, keeping keep: Int?, _ body: (inout DocumentCell, inout Document, LiveReplica) throws -> T,
  ) throws -> T {
    let replicas = documents.replicas
    return try replicas.with(id.key) { slot in
      var cell = self
      let stored = try storedDocument()
      if var document = stored.document {
        let replica = slot.take(document.frontier) { rebuild(document) }
        let value = try body(&cell, &document, replica)
        slot.keep(document.frontier)
        return value
      }
      let head = try DocumentRows.head(path, group, in: cell.host)
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
  func storedDocument() throws -> (document: Document?, stored: Bool) {
    guard let row = db.rows(DocumentStateRow.all).first else { return (nil, false) }
    guard let snapshot = db.rows(DocumentSnapshotRow.all).first else {
      preconditionFailure("\(id.key) holds state without a snapshot")
    }
    let document = Document(
      history: row.history, fileRev: row.fileRev, frontier: Data(row.frontier), nextSeq: row.nextSeq, dirtyAt: row.dirtyAt,
      snapshot: snapshot.snapshot, notDocument: row.notDocument,
    )
    guard let head = try DocumentRows.head(path, group, in: host) else { return (document.fileRev == nil ? document : nil, true) }
    return (document.fileRev == head.rev ? document : nil, true)
  }

  func rebuild(_ document: Document) -> LiveReplica {
    let log = db.rows(DocumentLogRow.all.order { $0.seq })
    do throws(LiveError) {
      return try LiveReplica(format, snapshot: Data(document.snapshot), updates: log.map { Data($0.bytes) })
    } catch {
      preconditionFailure("\(id.key) cannot rebuild from its own rows: \(error)")
    }
  }

  /// The document a file's text makes, its rows written when there is a file. `text` is the bytes a host
  /// fetched because they are not inline; a file whose bytes are not inline and were not handed in is one
  /// the cell cannot open now. Every start of a history clears what the path held.
  mutating func seeded(_ head: (rev: Int64, hash: String)?, _ text: Data?) throws -> (Document, LiveReplica) {
    let replica = LiveReplica(format)
    var document = Document(history: UUID().uuidString, fileRev: head?.rev, frontier: nil, nextSeq: 1, dirtyAt: nil, snapshot: [], notDocument: nil)
    guard let head else {
      try clear()
      return (document, replica)
    }
    guard let bytes = try DocumentRows.inlineText(head.hash, in: host) ?? text else { throw DocumentGone() }
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
    try writeSeed(document, replica)
    return (document, replica)
  }

  mutating func writeSeed(_ document: Document, _ replica: LiveReplica) throws {
    try clear()
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

  /// The text as one revision of the file, and the checkpoint the frontiers name it by.
  @discardableResult
  mutating func commit(
    _ document: inout Document, _ replica: LiveReplica, acting: GroupID, attribution: RevisionAttribution?, checkout: Int64? = nil,
    relaying update: Data? = nil, except skipped: Int? = nil,
  ) throws -> Int64 {
    let snapshot = Array(try! replica.snapshot())
    let rev = try DocumentRows.commit(
      path, group, acting: acting, attribution: attribution, text: replica.text, expecting: document.fileRev, checkout: checkout,
      mtime: documents.mtime(), in: host,
    )
    document.fileRev = rev
    document.frontier = replica.frontiers
    document.snapshot = snapshot
    document.dirtyAt = nil
    document.notDocument = nil
    try db.execute(DocumentStateRow.delete())
    try db.execute(DocumentLogRow.delete())
    try db.execute(
      DocumentStateRow.insert {
        DocumentStateRow(
          history: document.history, fileRev: rev, frontier: Array(replica.frontiers), nextSeq: document.nextSeq, dirtyAt: nil, notDocument: nil,
        )
      },
    )
    try saveSnapshot(snapshot)
    // An unchanged text commits at a revision that already has its row, whose frontiers this commit
    // replaces; every other checkpoint stays, an agent's base revision being one it read before this.
    try db.execute(DocumentCheckpointRow.where { $0.rev.eq(rev) }.delete())
    try db.execute(DocumentCheckpointRow.insert { DocumentCheckpointRow(rev: rev, frontiers: Array(replica.frontiers)) })
    if let update { send(.frame(.update(Array(update)))) }
    send(.control(.checkpoint(rev: Int(rev))), except: skipped)
    return rev
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
