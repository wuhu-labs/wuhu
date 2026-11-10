import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

public enum SessionCommand: Hashable, Sendable, Codable {
  case compact(instructions: String?)

  var kind: String {
    switch self {
    case .compact: "compact"
    }
  }

  var instructions: String? {
    switch self {
    case let .compact(instructions): instructions
    }
  }

  init?(kind: String, instructions: String?) {
    switch kind {
    case "compact": self = .compact(instructions: instructions)
    default: return nil
    }
  }
}

@Table("session_commands")
struct SessionCommandRow: Hashable, Sendable, Codable {
  @Column("session_id", primaryKey: true) var sessionID: String
  var kind: String
  var instructions: String?
  @Column("created_at") var createdAt: String

  var command: SessionCommand? { SessionCommand(kind: kind, instructions: instructions) }

  static func find(_ key: String, in db: Database) throws -> Self? {
    try Self.where { $0.sessionID.eq(key) }.fetchOne(db)
  }
}

extension SessionStore {
  public func pendingCommand(_ id: SessionID) async throws -> SessionCommand? {
    try await writer.read { db in try Sessions.pendingCommand(id.rawValue, in: db) }
  }
}

extension Sessions {
  static func discardCommand(_ key: String, in db: Database) throws {
    try SessionCommandRow.where { $0.sessionID.eq(key) }.delete().execute(db)
  }

  static func pendingCommand(_ key: String, in db: Database) throws -> SessionCommand? {
    try SessionCommandRow.find(key, in: db)?.command
  }
}
