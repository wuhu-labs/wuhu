import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

extension SpaceCell {
  func account(_ id: AccountID) -> AccountRecord? { ctx.cell(PersonCell.ID(id.rawValue)).account() }
  /// Every live account. A machine account's name is its machine's current alias: the account keeps none of its own.
  func accounts() -> [AccountRecord] {
    let names = Dictionary(uniqueKeysWithValues: db.rows(AliasRow.where { $0.kind.eq(AliasKind.machine) && $0.current }).map { ($0.target, $0.name) })
    let machineNames = Dictionary(uniqueKeysWithValues: db.rows(MachineRow.all).map { ($0.accountID, names[$0.id]) })
    return db.rows(PersonAccountRow.where { $0.removedAt.is(nil) }.order { ($0.createdAt, $0.id) }.select {
      PersonAccountRead.Columns(row: $0, admin: #sql("EXISTS(SELECT 1 FROM group_roles WHERE grp = \(bind: GroupID.settings.rawValue) AND account_id = \($0.id) AND role = 'admin')", as: Bool.self))
    }).map { read in
      let record = read.record
      guard record.kind == .machine, let name = machineNames[record.id.rawValue] ?? nil else { return record }
      return AccountRecord(id: record.id, kind: record.kind, name: name, isAdmin: record.isAdmin, guest: record.guest, createdAt: record.createdAt, removedAt: record.removedAt)
    }
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
    return db.rows(PersonaRow.where { $0.name.eq(principal) }).first.map { PersonCell.ID($0.accountID) }
  }

  func joinToken(_ hash: String) -> EnrollmentTokenRow? { db.rows(EnrollmentTokenRow.where { $0.tokenHash.eq(hash) }).first }
  func receipt(_ hash: String) -> PersonReceiptRow? { db.rows(PersonReceiptRow.where { $0.tokenHash.eq(hash) }).first }
}
