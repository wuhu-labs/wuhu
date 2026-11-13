import enum SpaceContract.Handle
import StructuredQueries
import Wuwei
import WuweiQueries

@Table("user_profiles")
struct UserProfileRow {
  @Column("principal", primaryKey: true) var principal: String
  @Column("owner_account") var ownerAccount: String
  @Column("display_name") var displayName: String?
}

public struct UserProfile: Equatable, Sendable {
  public let principal: String
  public let handle: String
  public let displayName: String?
}

extension Space {
  public func setUserProfile(principal: String, handle: String, displayName: String?) async throws -> UserProfile {
    guard let normalized = Handle.normalized(handle) else { throw SpaceError.invalidHandle(handle) }
    guard let owner = cell.personCell(principal), let account = worker.cell(owner).account(), account.removedAt == nil else { throw SpaceError.notFound(principal) }
    do { try await worker.call(SpaceCell.ID("space")) { try $0.renamePerson(principal, handle: normalized) } }
    catch AliasError.taken { throw SpaceError.handleTaken(normalized) }
    _ = try await worker.call(owner) { try $0.setDisplayName(principal, displayName: displayName) }
    return cell.userProfile(principal: principal)!
  }

  public func userProfile(principal: String) async throws -> UserProfile? { cell.userProfile(principal: principal) }
  public func userProfile(handle: String) async throws -> UserProfile? { cell.userProfile(handle: handle) }
  public func userProfiles() async throws -> [UserProfile] { cell.userProfiles() }
  public func handlesByPrincipal() async throws -> [String: String] { Dictionary(uniqueKeysWithValues: cell.userProfiles().map { ($0.principal, $0.handle) }) }
}

extension PersonCell {
  mutating func setDisplayName(_ principal: String, displayName: String?) throws -> Bool {
    try requireAccount()
    try db.execute(UserProfileRow.upsert { UserProfileRow(principal: principal, ownerAccount: id.key, displayName: displayName) })
    return true
  }
}

extension SpaceCell {
  func userProfile(principal: String) -> UserProfile? {
    db.rows(AliasRow.where { $0.kind.eq(AliasKind.person) && $0.current && $0.target.eq(principal) }.select {
      UserProfileRead.Columns(principal: $0.target, handle: $0.name, displayName: #sql("(SELECT display_name FROM user_profiles WHERE principal = \($0.target))", as: String?.self))
    }).first?.record
  }

  func userProfile(handle: String) -> UserProfile? {
    let handle = handle.lowercased()
    return db.rows(AliasRow.where {
      $0.kind.eq(AliasKind.person) && $0.current
        && $0.target.eq(#sql("(SELECT target FROM aliases WHERE name = \(bind: handle) AND kind = 'person')", as: String.self))
    }.select {
      UserProfileRead.Columns(principal: $0.target, handle: $0.name, displayName: #sql("(SELECT display_name FROM user_profiles WHERE principal = \($0.target))", as: String?.self))
    }).first?.record
  }

  func userProfiles() -> [UserProfile] {
    db.rows(AliasRow.where { $0.kind.eq(AliasKind.person) && $0.current }.order { $0.name }.select {
      UserProfileRead.Columns(principal: $0.target, handle: $0.name, displayName: #sql("(SELECT display_name FROM user_profiles WHERE principal = \($0.target))", as: String?.self))
    }).map(\.record)
  }
}

@Selection
private struct UserProfileRead {
  var principal: String
  var handle: String
  var displayName: String?

  var record: UserProfile { UserProfile(principal: principal, handle: handle, displayName: displayName) }
}
