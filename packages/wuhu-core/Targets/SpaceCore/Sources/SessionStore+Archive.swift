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
    let hydration = try await hydrate(id)
    var state = try await settleState(id)
    for queued in hydration.undrained {
      if let event = queued.input.settleEvent { state.apply(event) }
    }
    for open in state.openRequests.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
      _ = try await post(
        .conversation(open.conversation),
        messageID: MessageID(UUID.deterministic("archived-before-reporting", id.rawValue, open.id.rawValue).uuidString.lowercased()),
        sender: Sender(id: id.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: id,
        kind: .final,
        requestID: open.id,
        content: MessageContent(text: "session \(id.rawValue) (\(hydration.record.title)) was archived before reporting on request \(open.id.rawValue)"),
      )
      if let parent = hydration.record.parent {
        try await cancelSubscription(parent, subscriptionID: .deadline(open.id))
      }
    }
  }
}
