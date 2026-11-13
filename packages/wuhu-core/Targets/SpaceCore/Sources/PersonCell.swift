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

/// An account: a person’s, a machine’s or the space’s. The literal `owner` has only an inbox, with no account.
@Cell
public struct PersonCell {
  public static let owned = ["notifications": "owner_account", "watermarks": "owner_account", "user_profiles": "owner_account"]

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
