#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  public func move(
    _ path: String, in group: GroupID, to destination: String, in destinationGroup: GroupID, replacing: Bool, acting: GroupID,
    attribution: RevisionAttribution? = nil,
  ) async throws {
    try await live(group, acting: acting, attribution: attribution).move(
      MachineFolders.stored(path, mutating: true, in: runtime),
      to: MachineFolders.stored(destination, mutating: true, in: runtime),
      in: destinationGroup,
      replacing: replacing,
    )
  }

  public func writeFile(_ path: SpacePath, data: Data, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, ifMatch: VersionToken?, createOnly: Bool) async throws -> VersionToken {
    try await live(group, acting: acting, attribution: attribution).write(MachineFolders.stored(path, mutating: true, in: runtime).rawValue, data, ifMatch: ifMatch, createOnly: createOnly)
  }

  public func removeEmptyDirectory(_ path: SpacePath, in group: GroupID, acting: GroupID) async throws -> Bool {
    let path = try await MachineFolders.stored(path, mutating: true, in: runtime)
    guard !path.isRoot, !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    return try await worker.call(FilesCell.ID(group.rawValue)) { try $0.rmdir(path, mtime: mtime) }
  }

  public func currentRevision(in group: GroupID) async throws -> Int { Int(worker.cell(FilesCell.ID(group.rawValue)).currentRevision()) }

  public func history(_ path: SpacePath, in group: GroupID, after: Int? = nil, limit: Int? = nil) async throws -> [(Rev, Date, Change)] {
    let path = try await MachineFolders.stored(path, mutating: false, in: runtime)
    return worker.cell(FilesCell.ID(group.rawValue)).history(path, after: after ?? 0, limit: limit ?? Int.max)
  }

  public func attributions(of revisions: [(GroupID, Rev)]) async throws -> [GroupID: [Rev: RevisionAttribution]] {
    var found: [GroupID: [Rev: RevisionAttribution]] = [:]
    for (group, revisions) in Dictionary(grouping: revisions, by: \.0) {
      let keys = revisions.map { Int64($0.1.value) }
      for start in stride(from: 0, to: keys.count, by: 500) {
        let chunk = Array(keys[start ..< min(start + 500, keys.count)])
        let rows = worker.cell(FilesCell.ID(group.rawValue)).attributions(chunk)
        if !rows.isEmpty { found[group, default: [:]].merge(rows) { _, last in last } }
      }
    }
    return found
  }

  public func checkout(_ path: SpacePath, rev target: Rev, in group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, ifMatch: VersionToken? = nil, createOnly: Bool = false) async throws -> (Rev, VersionToken) {
    let path = try await MachineFolders.stored(path, mutating: true, in: runtime)
    guard !path.isReserved else { throw SpaceError.alreadyExists(path.rawValue) }
    let ceiling = Int64(target.value)
    try worker.cell(FilesCell.ID(group.rawValue)).requireRevision(ceiling)
    let node = worker.cell(FilesCell.ID(group.rawValue)).resolve(path.rawValue, at: ceiling)
    if path.isLive, let node {
      guard node.kind == "file" else { throw SpaceError.notAFile(path.rawValue) }
      let text = Data(try await bucket.bytes(node.blobHash!))
      if let ifMatch, ifMatch.rev == nil { throw SpaceError.versionMismatch(path.rawValue) }
      let base = ifMatch.map { DocumentBase.current(Int64($0.rev!)) } ?? .latest
      let rev = try await documents.write(group, path, text, base: base, createOnly: createOnly, acting: acting, attribution: attribution, checkout: ceiling)
      return (Rev(Int(rev)), VersionToken(rev: Int(rev)))
    }
    let restored: Blob?
    if node?.kind == "file" { restored = try await bucket.blob(node!.blobHash!) } else { restored = nil }
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let rev = try await worker.call(FilesCell.ID(group.rawValue)) {
      try $0.checkout(path, at: ceiling, restored: restored, ifMatch: ifMatch, createOnly: createOnly, mtime: mtime, attribution: attribution)
    }
    return (Rev(Int(rev)), VersionToken(rev: Int(rev)))
  }

  public func linkSources(into path: String, in group: GroupID) async throws -> [String] {
    worker.cell(FilesCell.ID(group.rawValue)).linkSources(into: path)
  }
}
