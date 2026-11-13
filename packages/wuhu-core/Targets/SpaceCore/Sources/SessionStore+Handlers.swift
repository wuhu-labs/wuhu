import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import struct Wuwei.Recipient

/// Whose a subscription is: a session's lives and ends with it; a group's
/// (an observer) lives until cancelled and has no agent to wake.
public enum SubscriptionOwner: Hashable, Sendable, Codable {
  case session(SessionID)
  case group(GroupID)

  var kind: String {
    switch self {
    case .session: "session"
    case .group: "group"
    }
  }

  var key: String {
    switch self {
    case let .session(id): id.rawValue
    case let .group(id): id.rawValue
    }
  }

  public var session: SessionID? {
    if case let .session(id) = self { id } else { nil }
  }

  public var group: GroupID? {
    if case let .group(id) = self { id } else { nil }
  }

  init(kind: String, key: String) {
    switch kind {
    case "session": self = .session(SessionID(key))
    case "group": self = .group(GroupID(rawValue: key))
    default: preconditionFailure("subscription_slots.owner_kind is checked: \(kind)")
    }
  }
}

/// An observer at its spend cap is paused until it is armed again.
public enum SubscriptionStatus: String, Hashable, Sendable {
  case armed
  case paused
}

@Table("subscription_slots")
public struct SubscriptionRow: Sendable {
  @Column("owner_kind") public var ownerKind: String
  public var owner: String
  @Column("subscription_id") public var subscriptionID: String
  public var name: String?
  public var status: String = SubscriptionStatus.armed.rawValue
  @Column("sessions_per_hour") public var sessionsPerHour: Int?
  public var payload: String
  @Column("next_fire_at") public var nextFireAt: String?
  public var marker: String?
  @Column("last_fired_at") public var lastFiredAt: String?
  @Column("armed_at") public var armedAt: String
  /// The input no firing has taken yet, as its handler gets it; newer rows replace older.
  @Column(as: JSONValue?.JSONRepresentation.self) public var pending: JSONValue? = nil
  @Column("pending_marker") public var pendingMarker: String? = nil

  public var subscriptionOwner: SubscriptionOwner { SubscriptionOwner(kind: ownerKind, key: owner) }

  public static func of(_ owner: SubscriptionOwner) -> Where<Self> {
    Self.where { $0.ownerKind.eq(owner.kind) && $0.owner.eq(owner.key) }
  }

  static func find(_ owner: SubscriptionOwner, _ subscription: String, in db: Database) throws -> Self? {
    try of(owner).where { $0.subscriptionID.eq(subscription) }.fetchOne(db)
  }

  static func find(_ session: String, _ subscription: String, in db: Database) throws -> Self? {
    try find(.session(SessionID(session)), subscription, in: db)
  }

  static func delete(_ owner: SubscriptionOwner, _ subscription: String, in db: Database) throws {
    try of(owner).where { $0.subscriptionID.eq(subscription) }.delete().execute(db)
  }

  static func save(_ row: Self, in db: Database) throws {
    try Self.insert { row } onConflict: {
      ($0.ownerKind, $0.owner, $0.subscriptionID)
    } doUpdate: {
      $0.payload = $1.payload
      $0.status = $1.status
      $0.nextFireAt = $1.nextFireAt
      $0.marker = $1.marker
      $0.lastFiredAt = $1.lastFiredAt
      $0.pending = $1.pending
      $0.pendingMarker = $1.pendingMarker
    }.execute(db)
  }
}

/// One handler firing as the log keeps it, from before it is dispatched:
/// `effects` names what it made, and an ended firing that made nothing is
/// kept for a week.
@Table("subscription_firings")
struct FiringRow {
  @Column(primaryKey: true) var id: String
  @Column("owner_kind") var ownerKind: String
  var owner: String
  var subscription: String
  var name: String?
  var grp: String
  var at: String
  var outcome: String
  var error: String?
  var effects: String?
}

enum FiringOutcome: String {
  case running
  case ok
  case failed
  /// Its owner could no longer act when it finished.
  case cancelled
}

extension SessionStore {
  static let noEffectFiringRetention: TimeInterval = 7 * 24 * 60 * 60

  // The group a live owner acts in; nil once the session is archived or the
  // group removed.
  static func actingGroup(of owner: SubscriptionOwner, in db: Database) throws -> GroupID? {
    switch owner {
    case let .session(id):
      let record = try Sessions.record(id.rawValue, in: db)
      return record.lifecycle == .live ? record.group : nil
    case let .group(id):
      return try GroupRow.where { $0.id.eq(id.rawValue) && $0.removedAt.is(nil) }.fetchOne(db).map { _ in id }
    }
  }

  // A running firing's end, with what it made: what it created (each stamped
  // with the firing) and the revisions it wrote. An ended firing stays as it
  // ended.
  static func endFiring(_ id: String, _ outcome: FiringOutcome, error: String? = nil, in db: Database) throws {
    var effects: [String: [String]] = [:]
    for row in try Row.fetchAll(db, sql: """
    SELECT 'sessions' AS kind, id FROM sessions WHERE firing = ?1
    UNION ALL SELECT 'requests', id FROM requests WHERE firing = ?1
    UNION ALL SELECT 'messages', id FROM messages WHERE firing = ?1
    UNION ALL SELECT 'revisions', grp || '/' || rev FROM revision_actors WHERE via = ?2
    """, arguments: [id, RevisionAttribution.firingVia(id)]) {
      effects[row["kind"] as String, default: []].append(row["id"])
    }
    let encoded = effects.isEmpty ? nil : try Sessions.encode(effects)
    try FiringRow.where { $0.id.eq(id) && $0.outcome.eq(FiringOutcome.running.rawValue) }.update {
      $0.outcome = #bind(outcome.rawValue)
      $0.error = #bind(error)
      $0.effects = #bind(encoded)
    }.execute(db)
  }

  static func pruneFirings(now: Date, in db: Database) throws {
    let cutoff = SQLiteDateFormat.string(from: now.addingTimeInterval(-noEffectFiringRetention))
    try FiringRow.where {
      $0.effects.is(nil) && $0.at.lt(cutoff) && $0.outcome.neq(FiringOutcome.running.rawValue)
    }.delete().execute(db)
  }
}

extension SessionStore {
  static func pause(_ row: SubscriptionRow, error: String, in db: Database) throws {
    var row = row
    var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
    slot.lastError = error
    row.payload = try Sessions.encode(slot)
    row.status = SubscriptionStatus.paused.rawValue
    try SubscriptionRow.save(row, in: db)
  }

  @discardableResult
  func armSubscription(
    _ key: String,
    slot: SubscriptionSlot,
    name: String? = nil,
    nextFireAt: Date?,
    marker: String?,
    now: String,
    in db: Database,
  ) throws -> ArmedSubscription {
    _ = try Sessions.record(key, in: db)
    let payload = try Sessions.encode(slot)
    try SubscriptionRow.insert {
      SubscriptionRow(
        ownerKind: SubscriptionOwner.session(SessionID(key)).kind, owner: key, subscriptionID: slot.id.rawValue,
        name: name ?? slot.handler.map(handlerName), payload: payload,
        nextFireAt: nextFireAt.map(SQLiteDateFormat.string(from:)), marker: marker,
        lastFiredAt: nil, armedAt: now,
      )
    } onConflict: { ($0.ownerKind, $0.owner, $0.subscriptionID) }.execute(db)
    let row = try SubscriptionRow.find(key, slot.id.rawValue, in: db)
    guard let row else { preconditionFailure("an armed slot must exist after its insert") }
    return try armedSubscription(row)
  }

  /// Arms `parent`'s children slot unless it stands; a new incarnation each
  /// time, so a firing of an earlier one cannot deliver into it.
  static func watchChildren(_ parent: SessionID, now: String, runtime: SpaceRuntime, in db: Database) throws {
    var slot = SubscriptionSlot(id: SubscriptionSlot.childrenID, kind: .children)
    slot.observationProgress = ObservationProgress(incarnation: UUID.deterministic("children", parent.rawValue, now), deliverySequence: 0)
    let row = SubscriptionRow(
      ownerKind: SubscriptionOwner.session(parent).kind, owner: parent.rawValue, subscriptionID: slot.id.rawValue,
      name: nil, payload: try Sessions.encode(slot), nextFireAt: nil, marker: nil, lastFiredAt: nil, armedAt: now,
    )
    try SubscriptionRow.insert { row } onConflict: { ($0.ownerKind, $0.owner, $0.subscriptionID) }.execute(db)
    let armed = try storelessArmedChildren(parent, in: db)
    try ObservationMail.recipient.post(.watch(armed.watch(recipient: Recipient<ObservationReply>(kind: "SessionCell", key: parent.rawValue))), on: db.sqliteConnection!)
    db.afterNextTransaction { _ in runtime.poke(ObservationMail.recipient) }
  }

  private static func storelessArmedChildren(_ parent: SessionID, in db: Database) throws -> ArmedSubscription {
    let row = try SubscriptionRow.find(parent.rawValue, SubscriptionSlot.childrenID.rawValue, in: db)!
    return ArmedSubscription(owner: .session(parent), status: .armed, slot: try Sessions.decode(SubscriptionSlot.self, from: row.payload), marker: row.marker, armedAt: try SQLiteDateFormat.date(from: row.armedAt))
  }

  /// Ends `parent`'s children slot once no live child is left.
  static func unwatchChildren(_ parent: SessionID, runtime: SpaceRuntime, in db: Database) throws {
    let live = try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE parent = ? AND lifecycle = 'live'", arguments: [parent.rawValue]) ?? 0
    guard live == 0 else { return }
    try deleteSubscription(parent.rawValue, SubscriptionSlot.childrenID, in: db)
    db.afterNextTransaction { _ in runtime.poke(ObservationMail.recipient) }
  }

  static func deleteSubscription(_ key: String, _ subscriptionID: SubscriptionID, in db: Database) throws {
    if subscriptionID == SubscriptionSlot.childrenID, let row = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db) {
      let slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
      let watched = ObservationSlot(owner: .session(SessionID(key)), subscription: subscriptionID, incarnation: slot.observationProgress!.incarnation)
      try ObservationMail.recipient.post(.unwatch(watched), on: db.sqliteConnection!)
    }
    try SubscriptionRow.delete(.session(SessionID(key)), subscriptionID.rawValue, in: db)
  }
}

extension SubscriptionRow {
  public init(owner: SubscriptionOwner, slot: SubscriptionSlot, name: String? = nil, sessionsPerHour: Int? = nil, nextFireAt: Date? = nil, marker: String? = nil, armedAt: Date) throws {
    self.init(ownerKind: owner.kind, owner: owner.key, subscriptionID: slot.id.rawValue, name: name ?? slot.handler.map(handlerName), sessionsPerHour: sessionsPerHour, payload: try Sessions.encode(slot), nextFireAt: nextFireAt.map(SQLiteDateFormat.string(from:)), marker: marker, lastFiredAt: nil, armedAt: SQLiteDateFormat.string(from: armedAt))
  }
}
