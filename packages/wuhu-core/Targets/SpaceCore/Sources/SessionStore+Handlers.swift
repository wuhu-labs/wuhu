import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import struct Wuwei.Recipient
import WuweiQueries

/// Whose a subscription is: a session's lives and ends with it; a group's
/// (an observer) lives until cancelled and has no agent to wake.
public enum SubscriptionOwner: Hashable, Sendable, Codable {
  case session(SessionID)
  case group(GroupID)

  public var kind: String {
    switch self {
    case .session: "session"
    case .group: "group"
    }
  }

  public var key: String {
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

  public static func find(_ owner: SubscriptionOwner, _ subscription: String, in db: Database) throws -> Self? {
    db.rows(of(owner).where { $0.subscriptionID.eq(subscription) }).first
  }

  public static func find(_ session: String, _ subscription: String, in db: Database) throws -> Self? {
    try find(.session(SessionID(session)), subscription, in: db)
  }

  public static func delete(_ owner: SubscriptionOwner, _ subscription: String, in db: inout Database) throws {
    try db.execute(of(owner).where { $0.subscriptionID.eq(subscription) }.delete())
  }

  public static func save(_ row: Self, in db: inout Database) throws {
    try db.execute(Self.insert { row } onConflict: {
      ($0.ownerKind, $0.owner, $0.subscriptionID)
    } doUpdate: {
      $0.payload = $1.payload
      $0.status = $1.status
      $0.nextFireAt = $1.nextFireAt
      $0.marker = $1.marker
      $0.lastFiredAt = $1.lastFiredAt
      $0.pending = $1.pending
      $0.pendingMarker = $1.pendingMarker
    })
  }
}

/// One handler firing as the log keeps it, from before it is dispatched:
/// `effects` names what it made, and an ended firing that made nothing is
/// kept for a week.
@Table("subscription_firings")
public struct FiringRow {
  @Column(primaryKey: true) public var id: String
  @Column("owner_kind") public var ownerKind: String
  public var owner: String
  public var subscription: String
  public var name: String?
  public var grp: String
  public var at: String
  public var outcome: String
  public var error: String?
  public var effects: String?

  public init(id: String, ownerKind: String, owner: String, subscription: String, name: String?, grp: String, at: String, outcome: String, error: String?, effects: String?) {
    self.id = id
    self.ownerKind = ownerKind
    self.owner = owner
    self.subscription = subscription
    self.name = name
    self.grp = grp
    self.at = at
    self.outcome = outcome
    self.error = error
    self.effects = effects
  }
}

public enum FiringOutcome: String {
  case running
  case ok
  case failed
  /// Its owner could no longer act when it finished.
  case cancelled
}

extension SubscriptionRow {
  public init(owner: SubscriptionOwner, slot: SubscriptionSlot, name: String? = nil, sessionsPerHour: Int? = nil, nextFireAt: Date? = nil, marker: String? = nil, armedAt: Date) throws {
    self.init(ownerKind: owner.kind, owner: owner.key, subscriptionID: slot.id.rawValue, name: name ?? slot.handler.map(handlerName), sessionsPerHour: sessionsPerHour, payload: try Sessions.encode(slot), nextFireAt: nextFireAt.map(SQLiteDateFormat.string(from:)), marker: marker, lastFiredAt: nil, armedAt: SQLiteDateFormat.string(from: armedAt))
  }
}

extension SessionStore {
  public static func actingGroup(of owner: SubscriptionOwner, in db: Database) throws -> GroupID? {
    switch owner {
    case let .session(id):
      let record = try Sessions.record(id.rawValue, in: db)
      return record.lifecycle == .live ? record.group : nil
    case let .group(id):
      return db.rows(GroupRow.where { $0.id.eq(id.rawValue) && $0.removedAt.is(nil) }).first.map { _ in id }
    }
  }
}
