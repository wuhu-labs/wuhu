#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import WuweiQueries

/// Something this generation of a session was shown, which a later tool call goes by: a file at a revision (what a write is checked against), a folder whose instructions were delivered with the repository root found for it, an instruction text by its hash with the path it first came from. Written by the session's cell with the item that shows it; a tool call reads the rows through the cell.
@Table("session_seen")
struct Seen: Owned, Hashable, Encodable, Sendable {
  var kind: Kind
  var key: String
  var value: String?

  enum Kind: String, QueryBindable, Encodable, Sendable {
    case file, folder, text
  }

  /// The row of the same thing seen before.
  var earlier: Where<Seen> {
    Seen.where { $0.kind.eq(kind) && $0.key.eq(key) }
  }

  /// A file's revision is JSON of our own making: a JSON column writes an mtime as an ISO string, which does not give the same Double back.
  static func folding(_ tools: ToolExecutionState) throws -> Set<Seen> {
    let encoder = JSONEncoder()
    var seen = Set(tools.folderRoots.map { Seen(kind: .folder, key: $0, value: $1) } + tools.deliveredContext.map { Seen(kind: .text, key: $0, value: $1) })
    for (path, revision) in tools.fileAccessLog {
      seen.insert(Seen(kind: .file, key: path, value: String(decoding: try encoder.encode(revision), as: UTF8.self)))
    }
    return seen
  }

  static func state(_ rows: [Seen]) throws -> ToolExecutionState {
    var state = ToolExecutionState()
    for seen in rows {
      switch seen.kind {
      case .file: state.fileAccessLog[seen.key] = try JSONDecoder().decode(FileRevision.self, from: Data(seen.value!.utf8))
      case .folder: state.folderRoots.updateValue(seen.value, forKey: seen.key)
      case .text: state.deliveredContext[seen.key] = seen.value!
      }
    }
    return state
  }

  /// What one item shows.
  static func of(_ item: TranscriptItem) throws -> Set<Seen> {
    guard let event = SessionEnvironment.Event(item) else { return [] }
    var environment = SessionEnvironment()
    environment.apply(event)
    return try folding(environment.tools)
  }
}
