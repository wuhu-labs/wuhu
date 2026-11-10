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
struct SubscriptionRow {
  @Column("owner_kind") var ownerKind: String
  var owner: String
  @Column("subscription_id") var subscriptionID: String
  var name: String?
  var status: String = SubscriptionStatus.armed.rawValue
  @Column("sessions_per_hour") var sessionsPerHour: Int?
  var payload: String
  @Column("next_fire_at") var nextFireAt: String?
  var marker: String?
  @Column("last_fired_at") var lastFiredAt: String?
  @Column("armed_at") var armedAt: String
  /// The input no firing has taken yet, as its handler gets it; newer rows replace older.
  @Column(as: JSONValue?.JSONRepresentation.self) var pending: JSONValue? = nil
  @Column("pending_marker") var pendingMarker: String? = nil

  var subscriptionOwner: SubscriptionOwner { SubscriptionOwner(kind: ownerKind, key: owner) }

  static func of(_ owner: SubscriptionOwner) -> Where<Self> {
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
    UNION ALL SELECT 'revisions', CAST(rev AS TEXT) FROM revision_actors WHERE via = ?2
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

extension Sessions {
  static func registeredSubscriptions(_ key: String, in db: Database) throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    let rows = try SubscriptionRow.of(.session(SessionID(key))).fetchAll(db)
    var ids: Set<SubscriptionID> = []
    var handlers: Set<SubscriptionID> = []
    for row in rows {
      let payload = JSONValue.parse(row.payload)?.object
      let id = SubscriptionID(row.subscriptionID)
      ids.insert(id)
      if case .string? = payload?["handler"] { handlers.insert(id) }
    }
    ids.formUnion(try pendingTimers(key, in: db).map(\.subscriptionID))
    ids.formUnion(try streams(key, in: db).map(\.id))
    return (ids, handlers)
  }
}

extension SessionStore {
  public func registeredSubscriptions(_ id: SessionID) async throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    try await writer.read { db in
      _ = try Sessions.record(id.rawValue, in: db)
      return try Sessions.registeredSubscriptions(id.rawValue, in: db)
    }
  }
}
