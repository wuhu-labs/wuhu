import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

@Table("revision_actors")
struct RevisionActorRow {
  @Column("grp") var grp: String
  @Column("rev") var rev: Int64
  @Column("actor") var actor: String?
  @Column("via") var via: String
}

enum JournalOp: String {
  case write
  case delete
  case move
  case checkout
}

enum Substrate {
  static func blobHash(_ content: [UInt8]) -> String {
    hexEncoded(SHA256.hash(data: Data(content)))
  }

  static func etag(for hash: String) -> String {
    String(hash.prefix(16))
  }

  static func lineCount(_ content: [UInt8]) -> Int? {
    guard let text = String(bytes: content, encoding: .utf8) else { return nil }
    if text.isEmpty { return 0 }
    let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    return text.hasSuffix("\n") ? newlines : newlines + 1
  }

  static func entryKind(_ kind: String) -> Entry.Kind {
    switch kind {
    case "directory": .directory
    case "table": .table
    default: .file
    }
  }

  static func entry(from head: FSHeadRow) -> Entry {
    Entry(
      name: SpacePath.lastComponent(of: head.path),
      kind: entryKind(head.kind),
      size: Int(head.size),
      lineCount: head.lineCount.map(Int.init),
      token: VersionToken(rev: Int(head.rev)),
      mtime: (try? SQLiteDateFormat.date(from: head.mtime)) ?? Date(timeIntervalSince1970: 0),
    )
  }
}

extension SpacePath {
  static func lastComponent(of raw: String) -> String {
    (try? SpacePath(validating: raw))?.lastComponent ?? raw
  }
}
