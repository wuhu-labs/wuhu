import GroupContract
import struct SpaceIDs.AccountID
import StructuredQueries
import TenancyContract
import Wuwei
import WuweiQueries

extension SpaceCell {
  func account(_ id: AccountID) -> AccountRecord? { ctx.cell(PersonCell.ID(id.rawValue)).account() }
  func accounts() -> [AccountRecord] {
    db.rows(PersonAccountRow.where { $0.removedAt.is(nil) }.order { ($0.createdAt, $0.id) }).map(\.record)
  }

  func hasAdminAccount() -> Bool { accounts().contains { ctx.settings().isSpaceAdmin(account: $0.id) } }
  func keyRecord(pubkey: String) -> KeyRecord? { db.rows(PersonKeyRow.where { $0.pubkey.eq(pubkey) }).first?.record }
  func readSession(_ token: ReadSessionToken) -> PersonReadSessionRow? {
    let hash = Space.credentialDigest(token.rawValue)
    return db.rows(PersonReadSessionRow.where { $0.tokenHash.eq(hash) }).first
  }

  func personCell(_ principal: String) -> PersonCell.ID? {
    if AccountID.isValid(principal) {
      return db.rows(PersonAccountRow.where { $0.id.eq(principal) }).first.map { PersonCell.ID($0.id) }
    }
    return db.rows(PersonaRow.where { $0.name.eq(principal) }).first.map { PersonCell.ID($0.accountID) }
  }

  func joinToken(_ hash: String) -> EnrollmentTokenRow? { db.rows(EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }).first }
}
