import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

extension SpaceCell {
  func account(_ id: AccountID) -> AccountRecord? { ctx.cell(PersonCell.ID(id.rawValue)).account() }
  func accounts() -> [AccountRecord] {
    db.rows(PersonAccountRow.where { $0.removedAt.is(nil) }.order { ($0.createdAt, $0.id) }.select {
      PersonAccountRead.Columns(row: $0, admin: #sql("EXISTS(SELECT 1 FROM group_roles WHERE grp = \(bind: GroupID.settings.rawValue) AND account_id = \($0.id) AND role = 'admin')", as: Bool.self))
    }).map(\.record)
  }

  func hasAdminAccount() -> Bool { accounts().contains(where: \.isAdmin) }
  func keyRecord(pubkey: String) -> KeyRecord? { db.rows(PersonKeyRow.where { $0.pubkey.eq(pubkey) }).first?.record }
  func readSession(_ token: ReadSessionToken) -> PersonReadSessionRow? {
    let hash = Space.credentialDigest(token.rawValue)
    return db.rows(PersonReadSessionRow.where { $0.tokenHash.eq(hash) }).first
  }

  func personCell(_ principal: String) -> PersonCell.ID? {
    if AccountID.isValid(principal) {
      return db.rows(PersonAccountRow.where { $0.id.eq(principal) }).first.map { PersonCell.ID($0.id) }
    }
    if principal == Notifications.ownerRecipient { return PersonCell.ID(principal) }
    return db.rows(PersonaRow.where { $0.name.eq(principal) }).first.map { PersonCell.ID($0.accountID) }
  }

  func joinToken(_ hash: String) -> EnrollmentTokenRow? { db.rows(EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }).first }
}
