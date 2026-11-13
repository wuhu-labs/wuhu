#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

/// A notice for a person's inbox, as whoever raises it mails it to the person's cell.
public struct PersonNote: Hashable, Codable, Sendable {
  /// What it is about: a conversation, or a session.
  public var source: String
  public var group: GroupID
  public var kind: NotificationKind
  public var payload: String
  public var createdAt: String
}

@Cell
public struct PersonCell {
  public static let owned = [
    "notifications": "owner_account", "watermarks": "owner_account", "user_profiles": "owner_account", "person_hidden_sidebars": "owner_account",
    "accounts": "owner", "account_keys": "owner", "read_sessions": "owner", "join_tokens": "owner", "join_token_receipts": "owner",
    "personas": "owner", "devices": "owner", "device_commands": "owner_account",
  ]

  public func notifications(after n: Int64 = 0) -> [NotificationRecord] {
    db.rows(NotificationRow.where { $0.ownerAccount.eq(id.key) && $0.n > n }.order(by: \.n)).map(NotificationRecord.init(row:))
  }

  public mutating func notify(_ recipient: String, _ note: PersonNote) throws {
    try db.execute(NotificationRow.insert {
      NotificationRow.Draft(
        recipient: recipient, ownerAccount: id.key, source: note.source, kind: note.kind.rawValue, payload: note.payload, createdAt: note.createdAt, group: note.group.rawValue,
      )
    })
    ctx.send(.changed, to: NotificationDeliveryJob.webPush)
    ctx.send(.changed, to: NotificationDeliveryJob.pushRelay)
  }

  /// Everything in the inbox now is read as far as `source` goes. Answers the mark: the newest notification's number.
  public mutating func read(_ identity: String, source: String) throws -> Int64 {
    let newest = db.rows(NotificationRow.where { $0.ownerAccount.eq(id.key) }.select { $0.n.max() }).first.flatMap(\.self) ?? 0
    try db.execute(WatermarkRow.insert {
      WatermarkRow(identity: identity, ownerAccount: id.key, source: source, lastReadN: newest)
    } onConflict: {
      ($0.identity, $0.source)
    } doUpdate: {
      $0.lastReadN = $1.lastReadN
    })
    return newest
  }

  /// The machine account's birth, if absent, then the mail that hands the machine its row: one step, so the row's
  /// account reference always names an account that exists.
  public mutating func machineAccount(_ claim: MachineClaim) throws {
    precondition(claim.account.rawValue == id.key)
    if db.rows(PersonAccountRow.where { $0.id.eq(id.key) }).isEmpty {
      try db.execute(PersonAccountRow.insert {
        PersonAccountRow(id: id.key, kind: AccountKind.machine.rawValue, name: nil, guest: false, createdAt: claim.created, removedAt: nil, owner: id.key)
      })
    }
    ctx.send(MachineCell.ID(claim.id.rawValue)).create(claim)
  }

  /// The account's last step: its devices, their commands and message links, its personas and its credentials go, and
  /// the account stays as a tombstone, which every read treats as gone.
  public mutating func removeMachineAccount(at now: Date) throws {
    try requireAccount()
    // Credentials first: a push registration's key reference cascades and its persona one does not.
    _ = try purgeCredentials()
    let devices = db.rows(DeviceRow.where { $0.accountID.eq(id.key) }.select(\.id))
    if !devices.isEmpty {
      try db.execute(MessageDeviceRow.where { $0.deviceID.in(devices) }.delete())
      try db.execute(DeviceCommandRow.where { $0.deviceID.in(devices) }.delete())
      try db.execute(DeviceRow.where { $0.accountID.eq(id.key) }.delete())
    }
    try db.execute(PersonaRow.where { $0.accountID.eq(id.key) }.delete())
    try db.execute(PersonAccountRow.where { $0.id.eq(id.key) }.update { $0.removedAt = #bind(SQLiteDateFormat.string(from: now)) })
  }
}

@Table("notifications")
struct NotificationRow {
  @Column(primaryKey: true) var n: Int64
  var recipient: String
  @Column("owner_account") var ownerAccount: String
  var source: String
  var kind: String
  var payload: String
  @Column("created_at") var createdAt: String
  @Column("grp") var group: String
}

@Table("watermarks")
struct WatermarkRow {
  var identity: String
  @Column("owner_account") var ownerAccount: String
  var source: String
  @Column("last_read_n") var lastReadN: Int64
}
