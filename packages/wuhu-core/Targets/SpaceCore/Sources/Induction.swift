import DocIndex
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

struct FileIndex: Codable, Sendable {
  var document: DocRow?
  var links: [LinkRow] = []
  var attrs: [DocCustomAttrRow] = []

  static func parse(_ path: SpacePath, group: GroupID, content: [UInt8]) -> Self {
    guard let meta = Induction.parse(path: path, content: content) else { return Self() }
    return Self(
      document: DocRow(grp: group.rawValue, path: path.rawValue, title: meta.title, kind: meta.kind, status: meta.status),
      links: (meta.links.map { (group.rawValue, $0) } + meta.groupLinks.map { ($0.group, $0.path) }).map {
        LinkRow(grp: group.rawValue, src: path.rawValue, dstGroup: $0.0, dst: $0.1.rawValue)
      },
      attrs: meta.customAttrs.flatMap { attr in
        Induction.flatten(attr.value).enumerated().map {
          DocCustomAttrRow(grp: group.rawValue, path: path.rawValue, name: attr.name, ord: Int64($0.offset), value: $0.element)
        }
      },
    )
  }

  func reparented(to path: SpacePath, in group: GroupID, from source: GroupID) -> Self {
    var result = self
    if result.document != nil { result.document!.grp = group.rawValue; result.document!.path = path.rawValue }
    for i in result.links.indices {
      result.links[i].grp = group.rawValue
      result.links[i].src = path.rawValue
      if result.links[i].dstGroup == source.rawValue { result.links[i].dstGroup = group.rawValue }
    }
    for i in result.attrs.indices { result.attrs[i].grp = group.rawValue; result.attrs[i].path = path.rawValue }
    return result
  }
}

enum Induction {
  static func flatten(_ value: DocMeta.AttrValue) -> [String] {
    switch value {
    case let .scalar(text): [text]
    case let .array(elements): elements
    case let .jsonObject(json): [json]
    }
  }

  static func parse(path: SpacePath, content: [UInt8]) -> DocMeta? {
    guard let text = String(bytes: content, encoding: .utf8) else { return nil }
    switch documentKind(of: path) {
    case .markdown: return DocIndex.parse(markdown: text, at: path)
    case .html: return DocIndex.parse(html: text, at: path)
    case .none: return nil
    }
  }

  private enum DocumentKind { case markdown, html }

  static func isDocument(_ path: SpacePath) -> Bool {
    documentKind(of: path) != nil
  }

  private static func documentKind(of path: SpacePath) -> DocumentKind? {
    guard let name = path.lastComponent?.lowercased() else { return nil }
    if name.hasSuffix(".md") || name.hasSuffix(".markdown") { return .markdown }
    if name.hasSuffix(".html") || name.hasSuffix(".htm") { return .html }
    return nil
  }
}

extension FilesCell {
  mutating func index(_ path: SpacePath, _ material: FileIndex) throws {
    try removeIndex(path)
    if let row = material.document { try db.execute(DocRow.insert { row }) }
    for row in material.links {
      let key = id.key
      if db.rows(LinkRow.where { $0.grp.eq(key) && $0.src.eq(row.src) && $0.dstGroup.eq(row.dstGroup) && $0.dst.eq(row.dst) }).isEmpty {
        try db.execute(LinkRow.insert { row })
      }
    }
    for row in material.attrs { try db.execute(DocCustomAttrRow.insert { row }) }
  }

  mutating func removeIndex(_ path: SpacePath) throws {
    let key = id.key
    try db.execute(DocRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.delete())
    try db.execute(LinkRow.where { $0.grp.eq(key) && $0.src.eq(path.rawValue) }.delete())
    try db.execute(DocCustomAttrRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }.delete())
  }

  func indexMaterial(_ path: SpacePath) -> FileIndex {
    let key = id.key
    return FileIndex(
      document: db.rows(DocRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }).first,
      links: db.rows(LinkRow.where { $0.grp.eq(key) && $0.src.eq(path.rawValue) }),
      attrs: db.rows(DocCustomAttrRow.where { $0.grp.eq(key) && $0.path.eq(path.rawValue) }),
    )
  }
}
