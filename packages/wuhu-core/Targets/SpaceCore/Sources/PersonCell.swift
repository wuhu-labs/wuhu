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

/// A person, keyed by the name their notifications are addressed to: a persona's, or `owner`. It keeps the inbox, which only `notify` mail adds to, and how far the person has read each source.
@Cell
public struct PersonCell {
  public static let owned = ["notifications": "recipient", "watermarks": "identity"]

  public func notifications(after n: Int64 = 0) -> [NotificationRecord] {
    db.rows(NotificationRow.where { $0.recipient.eq(id.key) && $0.n > n }.order(by: \.n)).map(NotificationRecord.init(row:))
  }

  public mutating func notify(_ note: PersonNote) throws {
    try db.execute(NotificationRow.insert {
      NotificationRow.Draft(
        recipient: id.key, source: note.source, kind: note.kind.rawValue, payload: note.payload, createdAt: note.createdAt, group: note.group.rawValue,
      )
    })
  }

  /// Everything in the inbox now is read as far as `source` goes. Answers the mark: the newest notification's number.
  public mutating func read(_ source: String) throws -> Int64 {
    let newest = db.rows(NotificationRow.where { $0.recipient.eq(id.key) }.select { $0.n.max() }).first.flatMap(\.self) ?? 0
    try db.execute(WatermarkRow.insert {
      WatermarkRow(identity: id.key, source: source, lastReadN: newest)
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
  var source: String
  var kind: String
  var payload: String
  @Column("created_at") var createdAt: String
  @Column("grp") var group: String
}

@Table("watermarks")
struct WatermarkRow {
  var identity: String
  var source: String
  @Column("last_read_n") var lastReadN: Int64
}
