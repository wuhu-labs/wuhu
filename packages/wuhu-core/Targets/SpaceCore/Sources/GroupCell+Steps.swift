import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei

/// What a group's creation carries: the alias the claim reserved, the name it goes by, who owns it and when.
public struct GroupClaim: Codable, Hashable, Sendable {
  public var alias: String
  public var name: String
  public var owner: AccountID
  public var created: String
}

extension GroupCell {
  /// What the apps call the project.
  public mutating func name(_ name: String) throws {
    _ = try live()
    try db.execute(GroupRow.where { $0.id.eq(id.key) }.update { $0.name = #bind(name) })
  }

  public mutating func setVisibility(_ visibility: GroupVisibility) throws {
    _ = try live()
    guard id.key != GroupID.settings.rawValue else { throw SpaceError.groupForbidden(id.key) }
    try db.execute(GroupRow.where { $0.id.eq(id.key) }.update { $0.visibility = #bind(visibility.rawValue) })
  }

  public mutating func setSecretsScope(_ scope: ReachScope) throws {
    try db.execute(GroupRow.where { $0.id.eq(id.key) }.update { $0.secretsScope = #bind(scope.rawValue) })
  }

  /// Puts `subjectID` on the list at `role`, replacing whatever it held: no group is listed in itself, a guest is no admin, and what it names must exist.
  public mutating func setGrant(_ subject: GroupGrant.Subject, _ subjectID: String, role: GroupRole, created: String) throws {
    try requireOrdinary()
    try requireSubject(subject, subjectID, role: role)
    let column = Self.column(of: subject)
    try db.execute("DELETE FROM group_roles WHERE grp = ? AND \(column) = ?", [.text(id.key), .text(subjectID)])
    try db.execute(
      "INSERT INTO group_roles (\(column), grp, role, created_at) VALUES (?, ?, ?, ?)",
      [.text(subjectID), .text(id.key), .text(role.rawValue), .text(created)],
    )
  }

  public mutating func removeGrant(_ subject: GroupGrant.Subject, _ subjectID: String) throws {
    try requireOrdinary()
    let column = Self.column(of: subject)
    try db.execute("DELETE FROM group_roles WHERE grp = ? AND \(column) = ?", [.text(id.key), .text(subjectID)])
    guard db.one("SELECT changes()")!.integer! > 0 else { throw SpaceError.notFound(subjectID) }
  }

  private func live() throws -> GroupRow {
    guard let row = rows.live(id.key) else { throw SpaceError.groupForbidden(id.key) }
    return row
  }

  /// A list's edits need a live group that is not the settings group, whose admins are the account admin verb's to set.
  private func requireOrdinary() throws {
    guard id.key != GroupID.settings.rawValue else { throw SpaceError.settingsGroupAccess }
    _ = try live()
  }

  private func requireSubject(_ subject: GroupGrant.Subject, _ subjectID: String, role: GroupRole) throws {
    switch subject {
    case .account:
      guard let account = GroupAccess.ActorRows(db).account(AccountID(rawValue: subjectID)), account.removedAt == nil else {
        throw SpaceError.notFound(subjectID)
      }
      guard !(role == .admin && account.guest) else { throw SpaceError.groupForbidden(id.key) }
    case .group:
      guard subjectID != id.key else { throw SpaceError.groupForbidden(id.key) }
      guard let target = db.rows(GroupRow.where { $0.id.eq(subjectID) }).first, target.removedAt == nil else {
        throw SpaceError.notFound(subjectID)
      }
    }
  }

  private static func column(of subject: GroupGrant.Subject) -> String {
    subject == .account ? "account_id" : "source_group"
  }
}
