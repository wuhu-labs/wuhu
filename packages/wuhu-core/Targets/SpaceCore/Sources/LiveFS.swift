import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import Wuwei

struct LiveFS: SpaceVFS {
  let group: GroupID
  let acting: GroupID
  let runtime: SpaceRuntime
  let bucket: Bucket
  let dateGen: DateGenerator
  let documents: DocumentHub
  var listingLimit: Int?
  var listingByteLimit: Int?
  var attribution: RevisionAttribution?

  var worker: Worker { runtime.worker() }

  func read(_ path: String) async throws -> (VersionToken, Data) {
    let p = try Self.validated(path)
    if p.isLive, documents.dirty(group, p) { await documents.checkpoint(group, p) }
    let (rev, hash) = try worker.cell(FilesCell.ID(group.rawValue)).fileContents(p)
    return (VersionToken(rev: Int(rev)), Data(try await bucket.bytes(hash)))
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    let p = try Self.validated(path)
    if p.isLive, documents.dirty(group, p) { await documents.checkpoint(group, p) }
    return BucketReader(bucket: bucket, hash: try worker.cell(FilesCell.ID(group.rawValue)).fileContents(p).hash)
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    try await write(path, data, ifMatch: ifMatch, createOnly: false)
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?, createOnly: Bool) async throws -> VersionToken {
    let p = try Self.validatedFileTarget(path)
    if p.isLive {
      if let ifMatch, ifMatch.rev == nil { throw SpaceError.versionMismatch(p.rawValue) }
      let base = ifMatch.map { DocumentBase.read(Int64($0.rev!)) } ?? .latest
      return try await VersionToken(rev: Int(documents.write(group, p, data, base: base, createOnly: createOnly, acting: acting, attribution: attribution)))
    }
    let blob = try await bucket.stage(Array(data)), mtime = SQLiteDateFormat.string(from: dateGen.now)
    let rev = try await worker.call(FilesCell.ID(group.rawValue)) {
      try $0.write(p, blob: blob, ifMatch: ifMatch, createOnly: createOnly, mtime: mtime, attribution: attribution)
    }
    return VersionToken(rev: Int(rev))
  }

  static func validatedFileTarget(_ path: String) throws -> SpacePath {
    let p = try validated(path, mutating: true)
    guard p.lastComponent?.hasSuffix(".table") != true else { throw SpaceError.reservedTablePath(p.rawValue) }
    return p
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    let p = try Self.validated(path, mutating: true), mtime = SQLiteDateFormat.string(from: dateGen.now)
    try await documents.checkpoint(under: p, in: group)
    try await worker.call(FilesCell.ID(group.rawValue)) { try $0.delete(p, ifMatch: ifMatch, mtime: mtime, attribution: attribution) }
  }

  func move(_ path: String, to destination: String) async throws {
    try await move(path, to: destination, replacing: false)
  }

  func move(_ path: String, to destination: String, replacing: Bool) async throws {
    try await move(path, to: destination, in: group, replacing: replacing)
  }

  func move(_ path: String, to destination: String, in destinationGroup: GroupID, replacing: Bool) async throws {
    let src = try Self.validated(path, mutating: true), dst = try Self.validated(destination, mutating: true)
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    try await documents.checkpoint(under: src, in: group)
    let (exported, external) = try worker.read { reader in
      let transfer = try reader.cell(FilesCell.ID(group.rawValue)).export(src)
      let external = Set(transfer.nodes.compactMap { node -> String? in
        guard let hash = node.head.blobHash, reader.cell(SpaceCell.ID("space")).bucket(hash)!.objectKey != nil else { return nil }
        return hash
      })
      return (transfer, external)
    }
    var transfer = exported
    if destinationGroup == group {
      var staged: [String: [String: FileIndex]] = [:]
      for node in transfer.nodes {
        let target = try Self.reparent(node.head.path, from: src, to: dst)
        guard node.head.kind == "file", Induction.isDocument(target), let hash = node.head.blobHash else { continue }
        if external.contains(hash) {
          staged[hash, default: [:]][target.rawValue] = .parse(target, group: group, content: try await bucket.bytes(hash))
        }
      }
      let indices = staged
      try await worker.call(FilesCell.ID(group.rawValue)) { try $0.move(src, to: dst, replacing: replacing, staged: indices, mtime: mtime, attribution: attribution) }
    } else {
      for i in transfer.nodes.indices {
        let target = try Self.reparent(transfer.nodes[i].head.path, from: src, to: dst)
        if transfer.nodes[i].head.kind == "file", Induction.isDocument(target) {
          transfer.nodes[i].index = .parse(target, group: destinationGroup, content: try await bucket.bytes(transfer.nodes[i].head.blobHash!))
        } else { transfer.nodes[i].index = FileIndex() }
      }
      let snapshot = transfer
      try await worker.call(FilesCell.ID(destinationGroup.rawValue)) { try $0.adopt(snapshot, at: dst, replacing: replacing, mtime: mtime, attribution: attribution) }
      try await worker.call(FilesCell.ID(group.rawValue)) { try $0.delete(snapshot, mtime: mtime, attribution: attribution) }
    }
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    let (entries, _, token) = try worker.cell(FilesCell.ID(group.rawValue)).page(Self.validated(path), from: "", limit: listingLimit ?? Int.max, budget: ListingBudget(limit: listingByteLimit))
    return (token, entries.sorted { $0.name < $1.name })
  }

  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    precondition(limit > 0)
    let (entries, next, _) = try worker.cell(FilesCell.ID(group.rawValue)).page(Self.validated(path), from: from, limit: limit, budget: ListingBudget(limit: nil))
    return (entries, next)
  }

  func stat(_ path: String) async throws -> Entry {
    try worker.cell(FilesCell.ID(group.rawValue)).entry(Self.validated(path))
  }

  static func validated(_ path: String, mutating: Bool = false) throws -> SpacePath {
    let p: SpacePath
    do { p = try SpacePath(validating: path) } catch { throw SpaceError.notFound(path) }
    if mutating, p.isReserved { throw SpaceError.alreadyExists(p.rawValue) }
    return p
  }

  static func checkIfMatch(_ ifMatch: VersionToken?, head: FSHeadRow?, path: SpacePath) throws {
    guard let ifMatch else { return }
    guard let head, let expected = ifMatch.rev, Int(head.rev) == expected else {
      throw SpaceError.versionMismatch(path.rawValue)
    }
  }

  static func reparent(_ path: String, from src: SpacePath, to dst: SpacePath) throws -> SpacePath {
    if path == src.rawValue { return dst }
    let suffix = path.dropFirst(src.rawValue.count)
    return try SpacePath(validating: dst.rawValue + suffix)
  }
}
