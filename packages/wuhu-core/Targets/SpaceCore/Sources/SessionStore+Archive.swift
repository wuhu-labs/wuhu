#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import Synchronization

@Table("sessions")
struct SessionTreeRow {
  var id: String
  var parent: String?
}

final class ArchiveReservations: Sendable {
  private let tokens = Mutex<[SessionID: UUID]>([:])

  func contains(_ id: SessionID) -> Bool { tokens.withLock { $0[id] != nil } }

  func reserve(_ id: SessionID, token: UUID) {
    tokens.withLock { $0[id] = token }
  }

  func release(_ id: SessionID, token: UUID) {
    tokens.withLock {
      if $0[id] == token { $0[id] = nil }
    }
  }
}

extension SessionStore {
  public func isReservedForArchive(_ id: SessionID) -> Bool {
    archiveReservations.contains(id)
  }

  public func reserveForArchive(_ id: SessionID, token: UUID) async throws {
    try await writer.write { db in
      _ = try Sessions.record(id.rawValue, in: db)
      self.archiveReservations.reserve(id, token: token)
    }
  }

  public func releaseArchiveReservation(_ id: SessionID, token: UUID) {
    archiveReservations.release(id, token: token)
  }

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
        alongside: { message, db in
          try Self.close(row, as: .failed, result: nil, now: SQLiteDateFormat.string(from: message.createdAt), in: db)
        },
      )
    }
  }
}
