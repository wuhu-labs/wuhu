import struct SpaceContract.HiddenSidebarAddress
import struct SpaceContract.UserSettingsPayload
import StructuredQueries
import Wuwei
import WuweiQueries

extension Space {
  public func userSettings(principal: String) throws -> UserSettingsPayload {
    guard let owner = cell.personCell(principal) else { throw SpaceError.notFound(principal) }
    return worker.cell(owner).settings()
  }

  public func setSidebarVisibility(principal: String, group: String, path: String, hidden: Bool) async throws -> UserSettingsPayload {
    guard let owner = cell.personCell(principal) else { throw SpaceError.notFound(principal) }
    return try await worker.call(owner) {
      try $0.setSidebarVisibility(group: group, path: path, hidden: hidden)
      return $0.settings()
    }
  }
}

extension PersonCell {
  public func settings() -> UserSettingsPayload {
    UserSettingsPayload(hidden: db.rows(PersonHiddenSidebarRow.where { $0.ownerAccount.eq(id.key) }.order { ($0.group, $0.path) }).map {
      HiddenSidebarAddress(group: $0.group, path: $0.path)
    })
  }

  public mutating func setSidebarVisibility(group: String, path: String, hidden: Bool) throws {
    try requireAccount()
    if hidden {
      try db.execute(PersonHiddenSidebarRow.insert {
        PersonHiddenSidebarRow(ownerAccount: id.key, group: group, path: path)
      } onConflict: { ($0.ownerAccount, $0.group, $0.path) })
    } else {
      try db.execute(PersonHiddenSidebarRow.where { $0.ownerAccount.eq(id.key) && $0.group.eq(group) && $0.path.eq(path) }.delete())
    }
  }
}

@Table("person_hidden_sidebars")
struct PersonHiddenSidebarRow {
  @Column("owner_account") var ownerAccount: String
  @Column("grp") var group: String
  var path: String
}
