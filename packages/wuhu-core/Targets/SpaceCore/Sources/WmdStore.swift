import Dependencies
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

@Table("wmd_snapshots")
struct WmdSnapshotRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("snapshot") var snapshot: [UInt8]
}

@Table("wmd_log")
struct WmdLogRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("seq") var seq: Int64
  @Column("bytes") var bytes: [UInt8]
}

@Table("wmd_checkpoints")
struct WmdCheckpointRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("rev") var rev: Int64
  @Column("frontiers") var frontiers: [UInt8]
}

@Selection private struct WmdLogged {
  var grp: String
  var path: String
}

struct WmdFile: Sendable {
  let rev: Int64
  let content: Data
}

struct WmdStored: Sendable {
  var snapshot: Data?
  var updates: [Data]
  var nextSeq: Int64
  /// The latest checkpoint: the file revision it wrote and the Loro frontiers it holds.
  var checkpoint: (rev: Int64, frontiers: Data)?
  var file: WmdFile?
  /// The space's revision when these were read.
  var seen: Int64
}

/// How a commit relates to the rows already stored for its path.
enum WmdLineage: Sendable, Equatable {
  case continues
  /// The document starts over: earlier rows describe a history it does not
  /// share. `seed` is the file revision it was built from, whose text these
  /// frontiers hold too.
  case restarts(seed: Int64?)
}

struct WmdCommit: Sendable {
  let markdown: String
  let snapshot: Data
  let frontiers: Data
  /// The last log sequence the snapshot holds.
  let through: Int64
  /// The file revision the node last saw; nil when it saw no file.
  let expecting: Int64?
  let lineage: WmdLineage
  /// The revision a checkout restores, journaled with the commit.
  let checkout: Int64?
  let acting: GroupID
  let attribution: RevisionAttribution?
}

/// The file a node built on is no longer at its path: deleted, moved away,
/// or replaced by a move.
struct WmdFileGone: Error {}

/// A `.wmd` node's durable state: its file, the snapshot and log behind it, and
/// the frontiers each checkpoint revision holds. Its node is the only writer of
/// the file, so a head at another revision than the node's means the file is gone.
struct WmdStore: Sendable {
  let writer: any DatabaseWriter
  let blobs: BlobStore
  let broadcast: FSBroadcast
  let dateGen: DateGenerator

  func load(_ group: GroupID, _ path: SpacePath) async throws -> WmdStored {
    try await blobs.read(writer) { db, cache in
      let (grp, raw) = (group.rawValue, path.rawValue)
      let snapshot = try WmdSnapshotRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.fetchOne(db)
      let log = try WmdLogRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.order { $0.seq }.fetchAll(db)
      let checkpoint = try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }
        .order { $0.rev.desc() }.limit(1).fetchOne(db)
      let file: WmdFile?
      if let head = try Substrate.head(path, group: group, in: db) {
        guard head.kind == "file", let hash = head.blobHash else { throw SpaceError.notAFile(path.rawValue) }
        file = WmdFile(rev: head.rev, content: Data(try cache.blob(of: hash, in: db).content))
      } else {
        file = nil
      }
      return WmdStored(
        snapshot: snapshot.map { Data($0.snapshot) },
        updates: log.map { Data($0.bytes) },
        nextSeq: (log.last?.seq ?? 0) + 1,
        checkpoint: checkpoint.map { ($0.rev, Data($0.frontiers)) },
        file: file,
        seen: try Substrate.maxRevision(in: db),
      )
    }
  }

  func hasLog(_ group: GroupID, _ path: SpacePath) async throws -> Bool {
    let (grp, raw) = (group.rawValue, path.rawValue)
    return try await writer.read { db in
      try WmdLogRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.limit(1).fetchOne(db) != nil
    }
  }

  /// Every node with logged edits no checkpoint holds yet.
  func logged() async throws -> [(group: GroupID, path: SpacePath)] {
    try await writer.read { db in
      try WmdLogRow.select { WmdLogged.Columns(grp: $0.grp, path: $0.path) }.distinct().fetchAll(db)
        .map { (GroupID(rawValue: $0.grp), try SpacePath(validating: $0.path)) }
    }
  }

  /// The frontiers of the checkpoint that wrote revision `rev`.
  func frontiers(_ group: GroupID, _ path: SpacePath, at rev: Int64) async throws -> Data? {
    let (grp, raw) = (group.rawValue, path.rawValue)
    return try await writer.read { db in
      try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) && $0.rev.eq(rev) }.fetchOne(db).map { Data($0.frontiers) }
    }
  }

  func append(_ group: GroupID, _ path: SpacePath, seq: Int64, _ bytes: Data, expecting: Int64?) async throws {
    let row = WmdLogRow(grp: group.rawValue, path: path.rawValue, seq: seq, bytes: Array(bytes))
    try await writer.write { db in
      guard try Substrate.head(path, group: group, in: db)?.rev == expecting else { throw WmdFileGone() }
      try WmdLogRow.insert { row }.execute(db)
    }
  }

  /// One revision: the canonical markdown as the file, the snapshot, the
  /// checkpoint's frontiers, and the log the snapshot now holds dropped.
  func commit(_ group: GroupID, _ path: SpacePath, _ commit: WmdCommit) async throws -> Int64 {
    let blob = try await blobs.stage(Array(commit.markdown.utf8))
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      let head = try Substrate.head(path, group: group, in: db)
      guard head?.rev == commit.expecting else { throw WmdFileGone() }
      let (grp, raw) = (group.rawValue, path.rawValue)
      var checkpoints: Set<Int64> = []
      if case let .restarts(seed) = commit.lineage {
        try Self.forget(path, group: group, in: db)
        if let seed { checkpoints.insert(seed) }
      }
      let rev: Int64
      switch try LiveFS.commitFile(
        path, group: group, acting: commit.acting, attribution: commit.attribution, blob: blob, head: head, mtime: mtime,
        op: commit.checkout == nil ? .write : .checkout, aux: commit.checkout.map(String.init), in: db,
      ) {
      case let .unchanged(unchanged):
        rev = unchanged
      case let .wrote(wrote):
        rev = wrote
        pending += [MutationEvent(group: group, path: raw, rev: Int(wrote), kind: .write, entry: .file)]
      }
      checkpoints.insert(rev)
      for at in checkpoints {
        try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) && $0.rev.eq(at) }.delete().execute(db)
        try WmdCheckpointRow.insert {
          WmdCheckpointRow(grp: grp, path: raw, rev: at, frontiers: Array(commit.frontiers))
        }.execute(db)
      }
      try WmdSnapshotRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.delete().execute(db)
      try WmdSnapshotRow.insert { WmdSnapshotRow(grp: grp, path: raw, snapshot: Array(commit.snapshot)) }.execute(db)
      try WmdLogRow.where { $0.grp.eq(grp) && $0.path.eq(raw) && $0.seq <= commit.through }.delete().execute(db)
      return rev
    }
  }

  /// Drops the rows of the node at `path`, in the mutation that removes its file.
  static func forget(_ path: SpacePath, group: GroupID, in db: Database) throws {
    guard path.isWmd else { return }
    let (grp, raw) = (group.rawValue, path.rawValue)
    try WmdSnapshotRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.delete().execute(db)
    try WmdLogRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.delete().execute(db)
    try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.delete().execute(db)
  }

  /// Carries the node's rows along with its file, in the move that lands it at
  /// `rev`: the moved text is the latest checkpoint's, so that checkpoint now
  /// wrote `rev` too. A file the rows do not describe, or one renamed off
  /// `.wmd`, leaves them behind.
  static func relocate(
    _ file: FSHeadRow, group: GroupID, to destination: SpacePath, in destinationGroup: GroupID, rev: Int64, in db: Database,
  ) throws {
    let path = try SpacePath(validating: file.path)
    guard path.isWmd, file.kind == "file" else { return }
    let (grp, raw, toGrp, toRaw) = (group.rawValue, path.rawValue, destinationGroup.rawValue, destination.rawValue)
    let latest = try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }.order { $0.rev.desc() }.limit(1).fetchOne(db)
    guard destination.isWmd, let latest, latest.rev == file.rev else { return try forget(path, group: group, in: db) }
    try WmdSnapshotRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }
      .update { $0.grp = #bind(toGrp); $0.path = #bind(toRaw) }.execute(db)
    try WmdLogRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }
      .update { $0.grp = #bind(toGrp); $0.path = #bind(toRaw) }.execute(db)
    try WmdCheckpointRow.where { $0.grp.eq(grp) && $0.path.eq(raw) }
      .update { $0.grp = #bind(toGrp); $0.path = #bind(toRaw) }.execute(db)
    try WmdCheckpointRow.insert { WmdCheckpointRow(grp: toGrp, path: toRaw, rev: rev, frontiers: latest.frontiers) }.execute(db)
  }
}

extension SpacePath {
  var isWmd: Bool { lastComponent?.hasSuffix(".wmd") == true }
}
