#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LiveDocument
import struct SpaceContract.GroupID
import enum SpaceContract.LiveErrorCode
import enum SpaceContract.LiveFrame
import struct SpaceContract.LivePeer
import enum SpaceContract.LiveServerControl
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

@Table("document_state")
struct DocumentStateRow: Owned {
  @Column("history") var history: String
  @Column("file_rev") var fileRev: Int64?
  @Column("frontier") var frontier: [UInt8]
  @Column("next_seq") var nextSeq: Int64
  @Column("dirty_at") var dirtyAt: Int64?
  /// Why the file's text is no document; only a write replaces it.
  @Column("not_document") var notDocument: String?
}

/// The snapshot of its own, so a changed frame's update of the state row rewrites a page and not the blob.
@Table("document_snapshot")
struct DocumentSnapshotRow: Owned {
  @Column("snapshot") var snapshot: [UInt8]
}

@Table("document_log")
struct DocumentLogRow: Owned {
  @Column("seq") var seq: Int64
  @Column("bytes") var bytes: [UInt8]
}

@Table("document_checkpoint")
struct DocumentCheckpointRow: Owned {
  @Column("rev") var rev: Int64
  @Column("frontiers") var frontiers: [UInt8]
}

@Table("document_lineage")
struct DocumentLineageRow: Owned {
  var lineage: Int64
  var seq: Int64
  @Column("seed_rev") var seedRev: Int64?
}

@Table("document_pending_checkpoint")
struct DocumentPendingCheckpointRow: Owned {
  var seq: Int64
  var frontiers: [UInt8]
}

/// A `.wmd` or `.canvas` file kept live for its open connections: the Loro log its clients typed, the
/// snapshot that log folds into, the revision each checkpoint wrote, and the relay between its sockets.
/// One cell per document, keyed `<group><path>`; the replica itself lives in ``DocumentReplicas``, and
/// a step uses it only while it reflects the row.
@Cell
struct DocumentCell {
  /// Changed frames a snapshot holds before the cell folds the log into it.
  static let foldLength = 64
  /// How long the file may lag the last changed frame.
  static let idleCheckpoint: Int64 = 5000

  static func key(_ group: GroupID, _ path: SpacePath) -> String {
    precondition(path.isLive, "a document cell is for a live path")
    return group.rawValue + path.rawValue
  }

  // MARK: Sockets

  mutating func attached(_ socket: SocketHandle<DocumentChannel>) {
    do {
      try ctx.cell(FilesCell.ID(group.rawValue)).requireAncestorDirectories(path)
      if ctx.cell(FilesCell.ID(group.rawValue)).file(path) == nil, !socket.opening.create || socket.opening.access != .write {
        throw LiveRefusal(code: .notFound, message: "\(path.rawValue) does not exist")
      }
      try withOpenDocument(file: ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path), existing: !socket.opening.create, keeping: socket.id) {
        cell, document, replica in
        if let reason = document.notDocument { throw LiveRefusal(code: .notLive, message: "\(cell.path.rawValue): \(reason)") }
        if document.fileRev == nil {
          guard socket.opening.create, socket.opening.access == .write else {
            throw LiveRefusal(code: .notFound, message: "\(cell.path.rawValue) does not exist")
          }
          try cell.commit(&document, replica, acting: cell.group, attribution: nil)
        }
        socket.send(
          .control(
            .welcome(
              connection: String(socket.id), name: socket.opening.name, access: socket.opening.access, peers: cell.peers(),
              rev: document.fileRev.map { Int($0) },
            ),
          ),
        )
        cell.send(.control(.peers(peers: cell.peers())), except: socket.id)
      }
    } catch is DocumentGone {
      refuse(socket, LiveRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted"))
    } catch let SpaceError.notADirectory(dir) {
      refuse(socket, LiveRefusal(code: .notFound, message: "\(dir) is a file, not a folder"))
    } catch let refusal as LiveRefusal {
      refuse(socket, refusal)
    } catch {
      preconditionFailure("a document step threw what a step does not: \(error)")
    }
  }

  mutating func receive(_ message: LiveInbound, from socket: SocketHandle<DocumentChannel>) {
    if case let .weakened(code) = message {
      refuse(
        socket,
        LiveRefusal(
          code: code,
          message: code == .readOnly
            ? "this connection may no longer write \(path.rawValue)"
            : "\(path.rawValue) is no longer readable from here",
        ),
      )
      return
    }
    do {
      guard case let .binary(bytes) = message else {
        throw LiveRefusal(code: .protocolViolation, message: "after hello, every client frame is binary")
      }
      let frame: LiveFrame
      do throws(LiveFrame.Malformed) { frame = try LiveFrame(bytes: bytes) } catch {
        throw LiveRefusal(code: .protocolViolation, message: "unknown frame tag \(error.tag.map(String.init) ?? "(empty frame)")")
      }
      switch frame {
      case let .sync(versionVector):
        try withCurrentDocument(ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)) { _, _, replica in
          let missing: Data?
          do { missing = try replica.updates(since: Data(versionVector)) } catch {
            throw LiveRefusal(code: .protocolViolation, message: "the sync frame holds no version vector")
          }
          if let missing { socket.send(.frame(.update(Array(missing)))) }
          socket.send(.frame(.synced(versionVector: Array(replica.versionVector))))
        }
      case let .update(bytes):
        guard socket.opening.access == .write else {
          throw LiveRefusal(code: .readOnly, message: "this connection reads \(path.rawValue) only")
        }
        try withCurrentDocument(ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)) { cell, document, replica in
          let changed: Bool
          do throws(LiveError) { changed = try replica.importClientUpdate(Data(bytes)) } catch {
            switch error {
            case .missingDependencies:
              throw LiveRefusal(code: .missingDependencies, message: "the update depends on operations the server lacks")
            default:
              throw LiveRefusal(code: .invalidUpdate, message: "\(error)")
            }
          }
          if changed {
            try cell.append(&document, replica, bytes)
            cell.send(.frame(.update(bytes)), except: socket.id)
            if cell.pendingUpdates() >= Self.foldLength { try cell.fold(&document, replica) }
          }
          socket.send(.control(.ack(count: 1)))
        }
      case let .presence(bytes):
        send(.frame(.presence(bytes)), except: socket.id)
      case .synced:
        throw LiveRefusal(code: .protocolViolation, message: "synced is the server's frame")
      }
    } catch is DocumentGone {
      refuse(socket, LiveRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted"))
    } catch let refusal as LiveRefusal {
      refuse(socket, refusal)
    } catch {
      preconditionFailure("a document step threw what a step does not: \(error)")
    }
  }

  mutating func closed(_ socket: SocketHandle<DocumentChannel>) {
    send(.control(.peers(peers: peers())), except: socket.id)
  }

  // MARK: Agents

  mutating func checkpoint() { _ = prepareCheckpoint() }

  mutating func committed(_ lineage: Int64, _ seq: Int64, _ rev: Int64, _ previous: Int64) throws {
    guard db.rows(DocumentLineageRow.all).first?.lineage == lineage else { return }
    if let pending = db.rows(DocumentPendingCheckpointRow.where { $0.seq.eq(seq) }).first {
      if db.rows(DocumentCheckpointRow.where { $0.rev.eq(rev) }).isEmpty {
        try db.execute(DocumentCheckpointRow.insert { DocumentCheckpointRow(rev: rev, frontiers: pending.frontiers) })
      }
      try db.execute(DocumentPendingCheckpointRow.where { $0.seq.eq(seq) }.delete())
      let current = db.rows(DocumentStateRow.all).first!.fileRev
      if current == nil || current! <= rev {
        try db.execute(DocumentStateRow.update { $0.fileRev = #bind(rev) })
        send(.control(.checkpoint(rev: Int(rev))))
      }
    }
    try db.execute(DocumentPendingCheckpointRow.where { $0.seq.gt(previous) && $0.seq.lt(seq) }.delete())
  }

  mutating func write(_ prepared: DocumentPrepared, _ request: DocumentWrite) throws -> DocumentWriteOutcome {
    try ctx.cell(FilesCell.ID(group.rawValue)).requireAncestorDirectories(path)
    do {
      return try documents.replicas.with(id.key) { slot in
        var cell = self
        let file = ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)
        let stored = try storedDocument(file)
        var document: Document
        let replica: LiveReplica
        switch prepared.history {
        case let .current(history):
          guard let current = stored.document, current.history == history else { return .stale }
          document = current
          replica = slot.take(document.frontier) { rebuild(document) }
        case let .seed(seed):
          guard stored.document == nil, try file.file()?.rev == seed.fileRev else { return .stale }
          for socket in sockets() {
            refuse(socket, LiveRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted"))
          }
          document = Document(
            history: seed.history, lineage: 0, fileRev: seed.fileRev, frontier: nil, nextSeq: 1, dirtyAt: nil,
            snapshot: Array(seed.snapshot), notDocument: seed.notDocument,
          )
          do throws(LiveError) {
            replica = try LiveReplica(format, snapshot: seed.snapshot, updates: [])
          } catch { preconditionFailure("a prepared seed cannot be imported: \(error)") }
          document.frontier = replica.frontiers
          try cell.writeSeed(&document, replica)
          slot.put(replica, document.frontier)
        }
        if request.createOnly, file.head != nil { throw SpaceError.alreadyExists(path.rawValue) }
        if case let .current(rev) = request.base, file.head?.rev != rev { throw SpaceError.versionMismatch(path.rawValue) }
        if let update = prepared.update {
          do throws(LiveError) { try replica.importUpdate(update) } catch {
            preconditionFailure("a prepared update must import completely into its own history: \(error)")
          }
        }
        let checkpoint = try cell.commit(
          &document, replica, acting: request.acting, attribution: request.attribution, checkout: request.checkout,
          relaying: prepared.update,
        )
        slot.keep(document.frontier)
        return .wrote(checkpoint)
      }
    } catch is DocumentGone {
      return .stale
    }
  }

  /// The text of a file whose bytes live in the object store, fetched by the host: the document's rows
  /// from it, when the file is still `rev` and the rows do not stand for it — absent, or left over from
  /// a history the file no longer is.
  mutating func seed(_ text: Data, _ rev: Int64) throws {
    try documents.replicas.with(id.key) { slot in
      let file = ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)
      let stored = try storedDocument(file)
      guard stored.document == nil, let head = try file.file(), head.rev == rev else { return }
      var cell = self
      let (document, replica) = try cell.seeded(head, text)
      slot.put(replica, document.frontier)
    }
  }

  mutating func removed(_ rev: Int64, lineage: Int64) {
    guard let current = db.rows(DocumentLineageRow.all).first, current.lineage == lineage else { return }
    let file = ctx.cell(FilesCell.ID(group.rawValue)).documentFile(path)
    if file.isCurrent(current.lineage, seedRev: current.seedRev), let head = file.head, head.rev >= rev { return }
    drop()
  }

  // MARK: Time

  func nextWake() -> Instant? {
    guard let dirty = db.rows(DocumentStateRow.all).first?.dirtyAt else { return nil }
    return Instant(milliseconds: dirty + Self.idleCheckpoint)
  }

  mutating func wake() {
    checkpoint()
  }

  // MARK: The document's own names

  func peers() -> [LivePeer] {
    roster(sockets())
  }

  func send(_ outbound: LiveOutbound, except skipped: Int? = nil) {
    for socket in sockets() where socket.id != skipped { socket.send(outbound) }
  }

  func sockets() -> [SocketHandle<DocumentChannel>] {
    ctx.sockets(of: DocumentChannel.self)
  }

  var group: GroupID { id.group }
  var path: SpacePath { id.path }
  var documents: Documents { ctx.dependency(Documents.self) }
  var format: LiveFormat { path.liveKind!.format }
  var notUTF8: String { "a .\(path.liveKind!.rawValue) file is UTF-8 text" }
}

extension Address where Target == DocumentCell {
  init(_ group: GroupID, _ path: SpacePath) {
    self.init(DocumentCell.key(group, path))
  }

  var group: GroupID { GroupID(rawValue: String(key.prefix { $0 != "/" })) }

  var path: SpacePath { try! SpacePath(validating: String(key.drop { $0 != "/" })) }
}
