import JSONValue
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

struct FileTransfer: Codable, Sendable {
  struct Table: Codable, Sendable {
    struct Row: Codable, Sendable { var id: Int64; var payload: String }
    var header: String
    var rows: [Row]
  }

  struct Node: Codable, Sendable {
    var head: FSHeadRow
    var index: FileIndex
    var table: Table?
  }

  var path: String
  var nodes: [Node]
}

extension FilesCell {
  func export(_ path: SpacePath) throws -> FileTransfer {
    guard file(path) != nil else { throw SpaceError.notFound(path.rawValue) }
    let key = id.key
    let nodes = try subtree(path).map { head -> FileTransfer.Node in
      let path = try SpacePath(validating: head.path)
      let table: FileTransfer.Table?
      if head.kind == "table" {
        table = FileTransfer.Table(
          header: Tables.encodeHeader(try currentHeader(path)),
          rows:
          db.rows(TableRowRow.where { $0.grp.eq(key) && $0.path.eq(head.path) && $0.deletedRev.is(nil) }.order { $0.rowID })
            .map { .init(id: $0.rowID, payload: $0.payload) },
        )
      } else { table = nil }
      return FileTransfer.Node(head: head, index: indexMaterial(path), table: table)
    }
    return FileTransfer(path: path.rawValue, nodes: nodes)
  }

  mutating func adopt(_ transfer: FileTransfer, at destination: SpacePath, replacing: Bool, mtime: String, attribution: RevisionAttribution?) throws {
    let head = transfer.nodes.first { $0.head.path == transfer.path }!.head
    if let existing = file(destination) {
      guard replacing, existing.kind == "file" else { throw SpaceError.alreadyExists(destination.rawValue) }
    }
    if (destination.lastComponent?.hasSuffix(".table") == true) != (head.kind == "table") { throw SpaceError.reservedTablePath(destination.rawValue) }
    try requireAncestorDirectories(destination)
    let rev = try mintRevision(mtime, attribution: attribution)
    let displaced = file(destination) != nil
    if displaced { try tombstone(destination, rev: rev, op: .delete) }
    try ensureAncestorDirectories(destination, rev: rev, mtime: mtime)
    try install(transfer, at: destination, rev: rev, mtime: mtime, displaced: displaced)
  }

  mutating func install(_ transfer: FileTransfer, at destination: SpacePath, rev: Int64, mtime: String, displaced: Bool) throws {
    let source = try SpacePath(validating: transfer.path)
    for node in transfer.nodes {
      let target = try LiveFS.reparent(node.head.path, from: source, to: destination)
      if let table = node.table {
        let header = try Tables.decodeHeader(table.header)
        let rows = table.rows.map { row in
          TableReplay.ReplayedRow(id: row.id, cells: Dictionary(uniqueKeysWithValues: JSONValue.parse(row.payload)!.object!.map { ($0.key, $0.value) }))
        }
        try installTable(target, header: header, rows: rows, rev: rev)
      }
      var head = node.head
      head.grp = id.key; head.path = target.rawValue; head.parentPath = target.parent.rawValue; head.rev = rev; head.mtime = mtime
      try appendVersion(target.rawValue, rev: rev, kind: head.kind, hash: head.blobHash, op: .write)
      try upsertHead(head)
      try index(target, node.index)
      if !displaced || target != destination { removed(target, rev: rev) }
    }
  }

  mutating func delete(_ transfer: FileTransfer, mtime: String, attribution: RevisionAttribution?) throws {
    let path = try SpacePath(validating: transfer.path)
    try requireUnchanged(transfer, at: path)
    let rev = try mintRevision(mtime, attribution: attribution)
    for node in transfer.nodes { try remove(node.head, rev: rev, op: .delete) }
  }

  func requireUnchanged(_ transfer: FileTransfer, at path: SpacePath) throws {
    let current = subtree(path)
    guard current.count == transfer.nodes.count,
          zip(current, transfer.nodes).allSatisfy({ $0.path == $1.head.path && $0.rev == $1.head.rev }) else { throw SpaceError.versionMismatch(path.rawValue) }
  }

  mutating func move(_ source: SpacePath, to destination: SpacePath, replacing: Bool, staged: [String: [String: FileIndex]], mtime: String, attribution: RevisionAttribution?) throws {
    var transfer = try export(source)
    if let existing = file(destination) {
      guard replacing, existing.kind == "file", destination != source else { throw SpaceError.alreadyExists(destination.rawValue) }
    }
    let root = transfer.nodes.first { $0.head.path == source.rawValue }!.head
    if (destination.lastComponent?.hasSuffix(".table") == true) != (root.kind == "table") { throw SpaceError.reservedTablePath(destination.rawValue) }
    try requireAncestorDirectories(destination)
    for i in transfer.nodes.indices {
      let node = transfer.nodes[i], target = try LiveFS.reparent(node.head.path, from: source, to: destination)
      if node.head.kind == "file", Induction.isDocument(target) {
        let hash = node.head.blobHash!
        switch try Bucket.stored(hash, in: db) {
        case let .inline(bytes): transfer.nodes[i].index = .parse(target, group: group, content: bytes)
        case .external:
          guard let material = staged[hash]?[target.rawValue] else { throw SpaceError.versionMismatch(source.rawValue) }
          transfer.nodes[i].index = material
        }
      } else { transfer.nodes[i].index = FileIndex() }
    }
    let rev = try mintRevision(mtime, attribution: attribution)
    let displaced = file(destination) != nil
    if displaced { try tombstone(destination, rev: rev, op: .delete) }
    for node in transfer.nodes {
      try remove(node.head, rev: rev, op: .move, aux: LiveFS.reparent(node.head.path, from: source, to: destination).rawValue)
    }
    try ensureAncestorDirectories(destination, rev: rev, mtime: mtime)
    try install(transfer, at: destination, rev: rev, mtime: mtime, displaced: displaced)
  }
}
