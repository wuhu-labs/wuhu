import Crypto
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import SpaceCore
import StructuredQueries

func seedBoxKey(space: Space, machine: String) async throws -> String {
  @Dependency(\.date) var date
  let now = date.now
  let stamp = SQLiteDateFormat.string(from: now)
  let pubkey = Curve25519.Signing.PrivateKey().pubkeyLabel
  return try await space.writer.write { db in
    let account: AccountID
    if let row = try MachineRow.where({ $0.id.eq(machine) }).fetchOne(db) {
      account = AccountID(rawValue: row.accountID)
    } else {
      account = AccountID(rawValue: "ac_" + UUID().uuidString.prefix(8).lowercased())
      try BoxMachineAccountRow.insert {
        BoxMachineAccountRow(id: account.rawValue, kind: "machine", name: machine, createdAt: stamp, removedAt: nil)
      }.execute(db)
      try MachineRow.insert {
        MachineRow(id: machine, accountID: account.rawValue, name: machine, createdAt: stamp, grp: "shared", scope: "owner")
      }.execute(db)
      try MachineV2MemberRow.insert {
        MachineV2MemberRow(machineID: machine, grp: "shared", createdAt: stamp)
      }.execute(db)
    }
    _ = try Space.insertKey(pubkey, account: account, capabilities: [.execMachine], createdBy: nil, createdAt: now, expiresAt: nil, in: db)
    return pubkey
  }
}

@Table("accounts")
private struct BoxMachineAccountRow {
  @Column(primaryKey: true) var id: String
  var kind: String
  var name: String?
  @Column("created_at") var createdAt: String
  @Column("removed_at") var removedAt: String?
}
