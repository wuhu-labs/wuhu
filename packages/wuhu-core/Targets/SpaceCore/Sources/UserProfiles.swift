import Foundation
import enum SpaceContract.Handle
import StructuredQueries
import StructuredQueriesSQLite

@Table("user_profiles")
struct UserProfileRow {
  @Column("principal", primaryKey: true) var principal: String
  @Column("handle") var handle: String
  @Column("display_name") var displayName: String?
  @Column("updated_at") var updatedAt: String
}

public struct UserProfile: Equatable, Sendable {
  public let principal: String
  public let handle: String
  public let displayName: String?
  public let updatedAt: Date
}

extension Space {
  public func setUserProfile(principal: String, handle: String, displayName: String?) async throws -> UserProfile {
    guard let normalized = Handle.normalized(handle) else { throw SpaceError.invalidHandle(handle) }
    let updatedAt = dateGen.now
    let row = UserProfileRow(
      principal: principal,
      handle: normalized,
      displayName: displayName,
      updatedAt: SQLiteDateFormat.string(from: updatedAt),
    )
    try await writer.write { db in
      do { try Aliases.requireFree(normalized, kind: .person, target: principal, in: db) }
      catch AliasError.taken { throw SpaceError.handleTaken(normalized) }
      try UserProfileRow.upsert { row }.execute(db)
    }
    return UserProfile(principal: principal, handle: normalized, displayName: displayName, updatedAt: updatedAt)
  }

  public func userProfile(principal: String) async throws -> UserProfile? {
    try await writer.read { db in
      try UserProfileRow.where { $0.principal.eq(principal) }.fetchOne(db).map(Self.userProfile(from:))
    }
  }

  public func userProfile(handle: String) async throws -> UserProfile? {
    return try await writer.read { db in
      guard let id = try Aliases.resolvePerson(handle, in: db) else { return nil }
      return try UserProfileRow.find(id).fetchOne(db).map(Self.userProfile(from:))
    }
  }

  public func userProfiles() async throws -> [UserProfile] {
    try await writer.read { db in
      try UserProfileRow.order { $0.handle }.fetchAll(db).map(Self.userProfile(from:))
    }
  }

  public func handlesByPrincipal() async throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try await userProfiles().map { ($0.principal, $0.handle) })
  }

  private static func userProfile(from row: UserProfileRow) -> UserProfile {
    UserProfile(
      principal: row.principal,
      handle: row.handle,
      displayName: row.displayName,
      updatedAt: (try? SQLiteDateFormat.date(from: row.updatedAt)) ?? Date(timeIntervalSince1970: 0),
    )
  }
}
