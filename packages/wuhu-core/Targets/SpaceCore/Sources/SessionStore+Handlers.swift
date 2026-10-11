import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import SessionDomain
import StructuredQueries

@Table("session_subscriptions")
struct SubscriptionRow {
  @Column("session_id") var sessionID: String
  @Column("subscription_id") var subscriptionID: String
  var payload: String
  @Column("next_fire_at") var nextFireAt: String?
  var marker: String?
  @Column("last_fired_at") var lastFiredAt: String?
  @Column("armed_at") var armedAt: String

  static func find(_ session: String, _ subscription: String, in db: Database) throws -> Self? {
    try Self.where { $0.sessionID.eq(session) && $0.subscriptionID.eq(subscription) }.fetchOne(db)
  }

  static func save(_ row: Self, in db: Database) throws {
    try Self.insert { row } onConflict: {
      ($0.sessionID, $0.subscriptionID)
    } doUpdate: {
      $0.payload = $1.payload
      $0.nextFireAt = $1.nextFireAt
      $0.marker = $1.marker
      $0.lastFiredAt = $1.lastFiredAt
    }.execute(db)
  }
}

public struct SubscriptionHandlerAttempt: Hashable, Sendable {
  public let session: SessionID
  public let subscriptionID: SubscriptionID
  public let incarnation: UUID
  public let attemptID: UUID
  public let stateJSON: String?
}

public enum SubscriptionHandlerResult: Sendable {
  case success(stateJSON: String, advance: SessionStore.SubscriptionAdvance, wakes: [SystemNotification])
  case failure(error: String, notification: SystemNotification, advance: SessionStore.SubscriptionAdvance? = nil)
}

enum SubscriptionHandlerStateError: Error, Sendable {
  case invalidJSON
  case tooLarge
}

extension SessionStore {
  public func beginSubscriptionHandler(
    _ id: SessionID,
    subscriptionID: SubscriptionID,
    incarnation: UUID,
    marker: String? = nil,
  ) async throws -> SubscriptionHandlerAttempt? {
    @Dependency(\.uuid) var uuid
    let attemptID = uuid()
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db -> SubscriptionHandlerAttempt? in
      guard var row = try SubscriptionRow.where({
        $0.sessionID.eq(id.rawValue) && $0.subscriptionID.eq(subscriptionID.rawValue)
      }).fetchOne(db), try Sessions.record(id.rawValue, in: db).lifecycle == .live
      else { return nil }
      var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
      guard slot.handler != nil, slot.handlerIncarnation == incarnation else { return nil }
      if let marker, marker == row.marker { return nil }
      slot.handlerAttemptID = attemptID
      row.payload = try Sessions.encode(slot)
      row.lastFiredAt = now
      try SubscriptionRow.save(row, in: db)
      return SubscriptionHandlerAttempt(
        session: id, subscriptionID: subscriptionID, incarnation: incarnation,
        attemptID: attemptID, stateJSON: slot.handlerStateJSON,
      )
    }
  }

  @discardableResult
  public func finishSubscriptionHandler(
    _ attempt: SubscriptionHandlerAttempt,
    result: SubscriptionHandlerResult,
  ) async throws -> Bool {
    let nowDate = dateGen.now
    let (finished, woke) = try await writer.write { db -> (Bool, Bool) in
      guard var row = try SubscriptionRow.where({
        $0.sessionID.eq(attempt.session.rawValue) && $0.subscriptionID.eq(attempt.subscriptionID.rawValue)
      }).fetchOne(db), try Sessions.record(attempt.session.rawValue, in: db).lifecycle == .live
      else { return (false, false) }
      var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
      guard slot.handler != nil, slot.handlerIncarnation == attempt.incarnation,
            slot.handlerAttemptID == attempt.attemptID
      else { return (false, false) }
      let advance: SubscriptionAdvance?
      let wakes: [SystemNotification]
      switch result {
      case let .success(stateJSON, next, notifications):
        guard stateJSON.utf8.count <= 16 * 1024 else { throw SubscriptionHandlerStateError.tooLarge }
        guard let state = JSONValue.parse(stateJSON) else { throw SubscriptionHandlerStateError.invalidJSON }
        let canonical = state.jsonString(sortedKeys: true)
        guard canonical.utf8.count <= 16 * 1024 else { throw SubscriptionHandlerStateError.tooLarge }
        slot.handlerStateJSON = canonical
        slot.lastError = nil
        slot.handlerFailed = nil
        advance = next
        wakes = notifications
      case let .failure(error, notification, next):
        wakes = slot.handlerFailed == true ? [] : [notification]
        slot.lastError = error
        slot.handlerFailed = true
        advance = next
      }
      slot.handlerAttemptID = nil
      if case let .reschedule(next) = advance {
        let due = try row.nextFireAt.map(SQLiteDateFormat.date(from:))
        guard let due, SQLiteDateFormat.string(from: next) > SQLiteDateFormat.string(from: due)
        else { throw NonAdvancingSubscription(due: due, next: next) }
        row.nextFireAt = SQLiteDateFormat.string(from: next)
      }
      if case let .observed(marker) = advance { row.marker = marker }
      row.payload = try Sessions.encode(slot)
      for wake in wakes {
        _ = try Sessions.enqueue(attempt.session.rawValue, input: .notification(wake), nowDate: nowDate, in: db)
      }
      if case .retire = advance {
        try SubscriptionRow.where {
          $0.sessionID.eq(attempt.session.rawValue) && $0.subscriptionID.eq(attempt.subscriptionID.rawValue)
        }.delete().execute(db)
      } else {
        try SubscriptionRow.save(row, in: db)
      }
      return (true, !wakes.isEmpty)
    }
    if woke { signals.post(attempt.session) }
    return finished
  }
}

extension Sessions {
  static func registeredSubscriptions(_ key: String, in db: Database) throws -> (ids: Set<SubscriptionID>, handlers: Set<SubscriptionID>) {
    let rows = try SubscriptionRow.where { $0.sessionID.eq(key) }.fetchAll(db)
    var ids: Set<SubscriptionID> = []
    var handlers: Set<SubscriptionID> = []
    for row in rows {
      let id = SubscriptionID(row.subscriptionID)
      ids.insert(id)
      if case .string? = JSONValue.parse(row.payload)?.object?["handler"] { handlers.insert(id) }
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
