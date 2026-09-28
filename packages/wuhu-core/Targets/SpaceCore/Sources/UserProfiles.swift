import Foundation
import StructuredQueries
import StructuredQueriesSQLite

let userProfileSchemaSQL = """
CREATE TABLE IF NOT EXISTS "user_profiles" (
  "principal" TEXT NOT NULL PRIMARY KEY,
  "handle" TEXT NOT NULL UNIQUE,
  "display_name" TEXT,
  "updated_at" TEXT NOT NULL
);
"""

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

public enum Handle {
  public static func normalized(_ raw: String) -> String? {
    normalizedLabel(raw, allowing: ["-"], length: 2 ... 32)
  }
}

func normalizedLabel(_ raw: String, allowing extras: Set<Character>, length: ClosedRange<Int>) -> String? {
  let lowered = raw.lowercased()
  guard length.contains(lowered.count), let first = lowered.first, isASCIIAlphanumeric(first) else { return nil }
  guard lowered.dropFirst().allSatisfy({ isASCIIAlphanumeric($0) || extras.contains($0) }) else { return nil }
  return lowered
}

private func isASCIIAlphanumeric(_ character: Character) -> Bool {
  character.isASCII && (("a" ... "z").contains(character) || ("0" ... "9").contains(character))
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
      let holder = try UserProfileRow.where { $0.handle.eq(normalized) }.fetchOne(db)
      guard holder == nil || holder?.principal == principal else { throw SpaceError.handleTaken(normalized) }
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
    let lowered = handle.lowercased()
    return try await writer.read { db in
      try UserProfileRow.where { $0.handle.eq(lowered) }.fetchOne(db).map(Self.userProfile(from:))
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
