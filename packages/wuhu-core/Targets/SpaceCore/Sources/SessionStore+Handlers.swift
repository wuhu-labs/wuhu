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
public enum SubscriptionOwner: Hashable, Sendable {
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

  /// Slots their own firing cancelled: when that firing is cut off rather
  /// than finished, they go with it.
  static let retiring = Self.where { #sql("json_type(\($0.payload), '$.handlerFiring.retiring') IS NOT NULL", as: Bool.self) }

  static func save(_ row: Self, in db: Database) throws {
    try Self.insert { row } onConflict: {
      ($0.ownerKind, $0.owner, $0.subscriptionID)
    } doUpdate: {
      $0.payload = $1.payload
      $0.status = $1.status
      $0.nextFireAt = $1.nextFireAt
      $0.marker = $1.marker
      $0.lastFiredAt = $1.lastFiredAt
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
  /// Its slot went, or another attempt took it, before it finished.
  case cancelled
  /// The server stopped while it ran.
  case interrupted
}

public struct SubscriptionHandlerAttempt: Hashable, Sendable {
  public let owner: SubscriptionOwner
  public let subscriptionID: SubscriptionID
  public let name: String?
  /// The group the firing acts in: the observer's, or its session's.
  public let group: GroupID
  public let incarnation: UUID
  /// The firing's id: what an observer's creations record.
  public let attemptID: UUID
  public let stateJSON: String?
  let startedAt: String

  /// The firing's id as what it makes records it.
  public var firing: String { attemptID.uuidString.lowercased() }
}

public enum SubscriptionHandlerResult: Sendable {
  case success(stateJSON: String, advance: SessionStore.SubscriptionAdvance, wakes: [SystemNotification])
  /// A failed firing's input stands: nothing advances, and the same input
  /// fires again.
  case failure(error: String, notification: SystemNotification)
}

enum SubscriptionHandlerStateError: Error, Sendable {
  case invalidJSON
  case tooLarge
}

extension SessionStore {
  static let noEffectFiringRetention: TimeInterval = 7 * 24 * 60 * 60

  public func beginSubscriptionHandler(
    _ owner: SubscriptionOwner,
    subscriptionID: SubscriptionID,
    incarnation: UUID,
    marker: String? = nil,
  ) async throws -> SubscriptionHandlerAttempt? {
    @Dependency(\.uuid) var uuid
    let attemptID = uuid()
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db -> SubscriptionHandlerAttempt? in
      guard var row = try SubscriptionRow.find(owner, subscriptionID.rawValue, in: db),
            row.status == SubscriptionStatus.armed.rawValue,
            let group = try Self.actingGroup(of: owner, in: db)
      else { return nil }
      var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
      guard slot.handler != nil, slot.handlerIncarnation == incarnation else { return nil }
      if case .retiring? = slot.handlerFiring { return nil }
      if let marker, marker == row.marker { return nil }
      slot.handlerFiring = .running(attemptID)
      row.payload = try Sessions.encode(slot)
      row.lastFiredAt = now
      try SubscriptionRow.save(row, in: db)
      let attempt = SubscriptionHandlerAttempt(
        owner: owner, subscriptionID: subscriptionID, name: row.name, group: group, incarnation: incarnation,
        attemptID: attemptID, stateJSON: slot.handlerStateJSON, startedAt: now,
      )
      try FiringRow.insert {
        FiringRow(
          id: attempt.firing, ownerKind: owner.kind, owner: owner.key, subscription: subscriptionID.rawValue,
          name: row.name, grp: group.rawValue, at: now, outcome: FiringOutcome.running.rawValue, error: nil, effects: nil,
        )
      }.execute(db)
      return attempt
    }
  }

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

  @discardableResult
  public func finishSubscriptionHandler(
    _ attempt: SubscriptionHandlerAttempt,
    result: SubscriptionHandlerResult,
  ) async throws -> Bool {
    let nowDate = dateGen.now
    let (finished, woke) = try await writer.write { db -> (Bool, Bool) in
      guard var row = try SubscriptionRow.find(attempt.owner, attempt.subscriptionID.rawValue, in: db),
            try Self.actingGroup(of: attempt.owner, in: db) != nil
      else {
        try Self.endFiring(attempt.firing, .cancelled, in: db)
        return (false, false)
      }
      var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
      guard slot.handler != nil, slot.handlerIncarnation == attempt.incarnation,
            let firing = slot.handlerFiring, firing.attempt == attempt.attemptID
      else {
        try Self.endFiring(attempt.firing, .cancelled, in: db)
        return (false, false)
      }
      let retiring = firing == .retiring(attempt.attemptID)
      var advance: SubscriptionAdvance?
      var wakes: [SystemNotification]
      let failure: String?
      switch result {
      case let .success(_, _, notifications) where retiring:
        wakes = notifications
        failure = nil
      case let .success(stateJSON, next, notifications):
        guard stateJSON.utf8.count <= 16 * 1024 else { throw SubscriptionHandlerStateError.tooLarge }
        guard let state = JSONValue.parse(stateJSON) else { throw SubscriptionHandlerStateError.invalidJSON }
        let canonical = state.jsonString(sortedKeys: true)
        guard canonical.utf8.count <= 16 * 1024 else { throw SubscriptionHandlerStateError.tooLarge }
        slot.handlerStateJSON = canonical
        if row.status == SubscriptionStatus.armed.rawValue { slot.lastError = nil }
        slot.handlerFailed = nil
        advance = next
        wakes = notifications
        failure = nil
      case let .failure(error, notification):
        wakes = slot.handlerFailed == true ? [] : [notification]
        slot.lastError = error
        slot.handlerFailed = true
        failure = error
      }
      // An observer has no agent: its wakes and failures live in the log.
      if attempt.owner.session == nil { wakes = [] }
      let retires = retiring || advance == .retire
      if retires {
        for index in wakes.indices { wakes[index].endsSubscription = true }
      }
      if let session = attempt.owner.session {
        for wake in wakes {
          _ = try Sessions.enqueue(session.rawValue, input: .notification(wake), nowDate: nowDate, in: db)
        }
      }
      if retires {
        try SubscriptionRow.delete(attempt.owner, attempt.subscriptionID.rawValue, in: db)
      } else {
        slot.handlerFiring = nil
        if case let .reschedule(next) = advance {
          let due = try row.nextFireAt.map(SQLiteDateFormat.date(from:))
          guard let due, SQLiteDateFormat.string(from: next) > SQLiteDateFormat.string(from: due)
          else { throw NonAdvancingSubscription(due: due, next: next) }
          row.nextFireAt = SQLiteDateFormat.string(from: next)
        }
        if let marker = advance?.marker { row.marker = marker }
        row.payload = try Sessions.encode(slot)
        try SubscriptionRow.save(row, in: db)
      }
      try Self.endFiring(attempt.firing, failure == nil ? .ok : .failed, error: failure, in: db)
      try Self.pruneFirings(now: nowDate, in: db)
      return (true, !wakes.isEmpty)
    }
    if woke, let session = attempt.owner.session { signals.post(session) }
    return finished
  }

  /// Ends a firing still logged as running: one cut off by a cancel whose
  /// task stopped before its slot's write. A slot retiring after this
  /// firing goes with it.
  public func cancelFiring(_ attempt: SubscriptionHandlerAttempt) async throws {
    try await writer.write { db in
      if let row = try SubscriptionRow.find(attempt.owner, attempt.subscriptionID.rawValue, in: db),
         try Sessions.decode(SubscriptionSlot.self, from: row.payload).handlerFiring == .retiring(attempt.attemptID)
      {
        try SubscriptionRow.delete(attempt.owner, attempt.subscriptionID.rawValue, in: db)
      }
      try Self.endFiring(attempt.firing, .cancelled, in: db)
    }
  }

  /// Ends every firing still logged as running: what the server was doing
  /// when it stopped.
  public func interruptFirings() async throws {
    try await writer.write { db in
      try SubscriptionRow.retiring.delete().execute(db)
      for id in try FiringRow.where({ $0.outcome.eq(FiringOutcome.running.rawValue) }).select(\.id).fetchAll(db) {
        try Self.endFiring(id, .interrupted, in: db)
      }
    }
  }

  // A running firing's end, with what it made: what it created (each stamped
  // with the firing) and the revisions it wrote. An ended firing stays as it
  // ended.
  private static func endFiring(_ id: String, _ outcome: FiringOutcome, error: String? = nil, in db: Database) throws {
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

  private static func pruneFirings(now: Date, in db: Database) throws {
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
      if payload?["handlerFiring"]?.object?["retiring"] != nil { continue }
      let id = SubscriptionID(row.subscriptionID)
      ids.insert(id)
      if case .string? = payload?["handler"] { handlers.insert(id) }
    }
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
