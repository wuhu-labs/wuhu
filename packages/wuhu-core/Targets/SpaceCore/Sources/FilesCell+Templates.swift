import struct DocIndex.DocumentTemplate
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

extension FilesCell {
  mutating func instantiate(_ template: DocumentTemplate, in directory: SpacePath, blob: Blob, now: Date, mtime: String, attribution: RevisionAttribution?) throws -> (SpacePath, Bool) {
    let key = id.key
    let names = db.rows(FSHeadRow.where { $0.grp.eq(key) && $0.parentPath.eq(directory.rawValue) && $0.kind.eq("file") }).map { SpacePath.lastComponent(of: $0.path) }
    let name = template.name(among: names, at: now, in: .current)
    let target = try SpacePath(validating: directory.isRoot ? "/\(name)" : "\(directory.rawValue)/\(name)")
    if target.isReserved || file(target) != nil || tableExists(target) { throw SpaceError.alreadyExists(target.rawValue) }
    guard !target.isLive else { return (target, false) }
    _ = try write(target, blob: blob, ifMatch: nil, createOnly: true, mtime: mtime, attribution: attribution)
    return (target, true)
  }

  func fileHeads() -> [FSHeadRow] {
    let key = id.key
    return db.rows(FSHeadRow.where { $0.grp.eq(key) && $0.kind.eq("file") })
  }

  func tablePaths() -> [String] {
    let key = id.key
    return db.rows(TableNodeRow.where { $0.grp.eq(key) }.order { $0.path }.select { $0.path })
  }

  func exportTable(_ path: SpacePath) throws -> (TableHeader, [[Value]]) {
    let header = try currentHeader(path)
    guard !header.columns.isEmpty else { return (header, []) }
    let columns = header.columns.map { Cells.quote($0.name) }.joined(separator: ", ")
    return (header, db.rows("SELECT \(columns) FROM \(Tables.quoted(group, path)) ORDER BY id").map { row in header.columns.indices.map { row[$0] } })
  }
}
