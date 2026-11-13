#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries

@Table("sessions")
struct SessionTreeRow {
  var id: String
  var parent: String?
}

extension SessionStore {
  public func archiveSubtree(_ root: SessionID) async throws -> [SessionRecord] {
    return try spaceCell.sessionArchiveSubtree(root)
  }

  public func closeRequestsForArchive(_ id: SessionID) async throws {
    let record = try await record(id)
    let now = dateGen.now
    try await runtime.worker().call(Self.requests(of: id, askedBy: record.parent)) { try $0.archived(id, title: record.title, at: now) }
  }
}
