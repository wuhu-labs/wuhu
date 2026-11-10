#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

@Table("sessions")
struct SessionTreeRow {
  var id: String
  var parent: String?
}

extension SessionStore {
  public func archiveSubtree(_ root: SessionID) async throws -> [SessionRecord] {
    try await writer.read { db in
      _ = try Sessions.record(root.rawValue, in: db)
      let rows = try SessionTreeRow.all.order(by: \.id).fetchAll(db)
      let children = Dictionary(grouping: rows.filter { $0.parent != nil }, by: { $0.parent! })
      var ordered: [SessionRecord] = []
      func visit(_ id: String, depth: Int) throws {
        precondition(depth <= Self.depthLimit, "session tree cycle below \(root.rawValue)")
        for child in children[id, default: []] { try visit(child.id, depth: depth + 1) }
        try ordered.append(Sessions.record(id, in: db))
      }
      try visit(root.rawValue, depth: 1)
      return ordered
    }
  }

  public func closeRequestsForArchive(_ id: SessionID) async throws {
    let (record, open) = try await writer.read { db in
      try (Sessions.record(id.rawValue, in: db), RequestRow.open(task: id.rawValue, in: db).map { ($0, try $0.replyTarget(in: db)) })
    }
    for (row, target) in open {
      _ = try await post(
        target,
        messageID: MessageID(UUID.deterministic("archived-before-reporting", id.rawValue, row.id).uuidString.lowercased()),
        sender: Sender(id: id.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: id,
        kind: .final,
        requestID: RequestID(row.id),
        content: MessageContent(text: "session \(id.rawValue) (\(record.title)) was archived before reporting on request \(row.id)"),
        request: .close(as: .failed, result: nil),
      )
    }
  }
}
