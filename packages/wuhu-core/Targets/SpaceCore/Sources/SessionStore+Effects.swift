import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS

public struct RecordedWrite: Sendable {
  public let payload: ToolResultPayload
  public let replayed: Bool
}

extension SessionStore {
  // The fs journal write and the receipt commit in one transaction: there is
  // no crash window in which the effect happened but the receipt did not, so
  // a retry can never report a false failure for its own write. A nil
  // toolCallID (a run_script write, which nothing replays) records no receipt.
  public func recordedSpaceWrite(
    _ id: SessionID,
    toolCallID: ToolCallID?,
    path: String,
    in group: GroupID,
    content: Data,
    ifMatchRev: Int64?,
    payload: @escaping @Sendable (Int64) -> ToolResultPayload,
  ) async throws -> RecordedWrite {
    let key = id.rawValue
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let p = try await LiveFS.validatedFileTarget(MachineFolders.stored(path, mutating: true, in: writer))
    let home = try await writer.read { db in try Sessions.group(of: key, in: db) }
    try SessionHome.refuseForeignWrite(to: p, in: group, by: id, home: home)
    try await writer.read { db in try GroupLayer.refuseWrite(p, in: group, by: .session(id), in: db) }
    let blob = try await blobs.stage(Array(content))
    let (result, broadcastRev): (RecordedWrite, Int64?) = try await writer.write { db in
      if let toolCallID, let recorded = try Sessions.receipt(key, toolCallID: toolCallID.rawValue, in: db) {
        return (RecordedWrite(payload: recorded, replayed: true), nil)
      }
      let head = try Substrate.head(p, group: group, in: db)
      // ifMatchRev nil is the creation case: the guard admitted the write only
      // because no read was logged, so the file must not exist yet.
      switch (ifMatchRev, head) {
      case (nil, nil):
        break
      case let (rev?, head?) where head.rev == rev:
        break
      default:
        throw SpaceError.versionMismatch(p.rawValue)
      }
      let outcome = try LiveFS.commitFile(p, group: group, acting: home, blob: blob, head: head, mtime: mtime, in: db)
      let rev: Int64
      var wrote: Int64?
      switch outcome {
      case let .unchanged(current):
        rev = current
      case let .wrote(minted):
        rev = minted
        wrote = minted
      }
      let built = payload(rev)
      if let toolCallID {
        try Sessions.recordReceipt(
          key, toolCallID: toolCallID.rawValue, payload: try Sessions.encode(built), now: mtime, in: db,
        )
      }
      return (RecordedWrite(payload: built, replayed: false), wrote)
    }
    if let rev = broadcastRev {
      broadcast.emit(MutationEvent(group: group, path: p.rawValue, rev: Int(rev), kind: .write, entry: .file))
    }
    return result
  }
}

struct ObservationProgress: Hashable, Sendable, Codable {
  var incarnation: UUID
  var deliverySequence: Int
}

public struct SubscriptionSlot: Hashable, Sendable, Codable {
  public enum Kind: Hashable, Sendable, Codable {
    case observe(sql: String, throttleSeconds: Double)
    case timer(TimerSchedule, message: String)
    case parkReminder(request: RequestID)
    case requestDeadline(request: RequestID, task: SessionID)
  }

  public var id: SubscriptionID
  public var kind: Kind
  var observationProgress: ObservationProgress?

  public init(id: SubscriptionID, kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

public struct ArmedSubscription: Hashable, Sendable {
  public var session: SessionID
  public var slot: SubscriptionSlot
  public var nextFireAt: Date?
  public var marker: String?
  public var lastFiredAt: Date?
}

extension SessionStore {
  // Re-arming an existing subscription id is a crash-retry: the original slot
  // (and its firing progress) stands, and the returned record is the stored
  // slot's truth, never an echo of the new arguments.
  @discardableResult
  public func armSubscription(
    _ id: SessionID,
    slot: SubscriptionSlot,
    nextFireAt: Date? = nil,
    marker: String? = nil,
  ) async throws -> ArmedSubscription {
    @Dependency(\.uuid) var uuid
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    var inserted = slot
    if case .observe = inserted.kind, inserted.observationProgress == nil {
      inserted.observationProgress = ObservationProgress(incarnation: uuid(), deliverySequence: 0)
    }
    let payload = try Sessions.encode(inserted)
    return try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(
        sql: """
        INSERT OR IGNORE INTO session_subscriptions
          (session_id, subscription_id, payload, next_fire_at, marker, armed_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: [key, slot.id.rawValue, payload, nextFireAt.map(SQLiteDateFormat.string(from:)), marker, now],
      )
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
        arguments: [key, slot.id.rawValue],
      )
      guard let row else { preconditionFailure("an armed slot must exist after its insert") }
      return try self.armedSubscription(row)
    }
  }

  public func cancelSubscription(_ id: SessionID, subscriptionID: SubscriptionID) async throws {
    let key = id.rawValue
    try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
        arguments: [key, subscriptionID.rawValue],
      )
    }
  }

  public func armedSubscriptions() async throws -> [ArmedSubscription] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM session_subscriptions ORDER BY session_id, subscription_id",
      ).map(armedSubscription)
    }
  }

  @_spi(SessionObservation)
  public func subscriptionRegistrations() async throws -> [(subscription: ArmedSubscription, callbackID: UUID?)] {
    try await writer.read { db in try subscriptionRegistrations(in: db) }
  }

  @_spi(SessionObservation)
  public func observeArmedSubscriptions()
    -> some AsyncSequence<[(subscription: ArmedSubscription, callbackID: UUID?)], any Error> & Sendable
  {
    ValueObservation
      .tracking { db in try subscriptionRegistrations(in: db) }
      .values(in: writer, bufferingPolicy: .bufferingNewest(1))
  }

  private func subscriptionRegistrations(in db: Database) throws -> [(subscription: ArmedSubscription, callbackID: UUID?)] {
    try Row.fetchAll(
      db,
      sql: "SELECT * FROM session_subscriptions ORDER BY session_id, subscription_id",
    ).map { row in
      let subscription = try armedSubscription(row)
      guard case .observe = subscription.slot.kind else { return (subscription, nil) }
      return (subscription, observationToken(subscription))
    }
  }

  public func armedSubscriptions(_ id: SessionID) async throws -> [ArmedSubscription] {
    let key = id.rawValue
    return try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM session_subscriptions WHERE session_id = ? ORDER BY subscription_id",
        arguments: [key],
      ).map(armedSubscription)
    }
  }

  func armedSubscription(_ row: Row) throws -> ArmedSubscription {
    ArmedSubscription(
      session: SessionID(row["session_id"] as String),
      slot: try Sessions.decode(SubscriptionSlot.self, from: row["payload"]),
      nextFireAt: try (row["next_fire_at"] as String?).map(SQLiteDateFormat.date(from:)),
      marker: row["marker"],
      lastFiredAt: try (row["last_fired_at"] as String?).map(SQLiteDateFormat.date(from:)),
    )
  }

  public enum SubscriptionAdvance: Hashable, Sendable {
    case retire
    case reschedule(Date)
    case observed(marker: String)
  }

  @discardableResult
  public func fireSubscription(
    _ id: SessionID,
    subscriptionID: SubscriptionID,
    notification: SystemNotification,
    advance: SubscriptionAdvance,
  ) async throws -> Int {
    let key = id.rawValue
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    let row = try await writer.write { db in
      if case let .reschedule(next) = advance {
        guard let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
          arguments: [key, subscriptionID.rawValue],
        ) else { throw StaleSubscriptionCallback() }
        let due = try armedSubscription(row).nextFireAt
        guard let due, SQLiteDateFormat.string(from: next) > SQLiteDateFormat.string(from: due)
        else { throw NonAdvancingSubscription(due: due, next: next) }
      }
      var delivered = notification
      var advancedObservation: SubscriptionSlot?
      if notification.kind == .spaceObservation {
        guard let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
          arguments: [key, subscriptionID.rawValue],
        ) else { throw StaleSubscriptionCallback() }
        let current = try armedSubscription(row)
        guard case .observe = current.slot.kind, notification.id == observationToken(current)
        else { throw StaleSubscriptionCallback() }

        if case let .observed(marker) = advance {
          guard marker != current.marker else { throw StaleSubscriptionCallback() }
          var progress = observationProgress(current)
          progress.deliverySequence += 1
          var slot = current.slot
          slot.observationProgress = progress
          delivered.id = UUID.deterministic(
            "observe",
            key,
            slot.id.rawValue,
            progress.incarnation.uuidString.lowercased(),
            String(progress.deliverySequence),
          )
          advancedObservation = slot
        } else {
          delivered.id = UUID.deterministic("observe-error", key, subscriptionID.rawValue)
        }
      }

      let enqueued = try Sessions.enqueue(key, input: .notification(delivered), nowDate: nowDate, in: db)
      if notification.kind == .requestDeadline {
        guard let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
          arguments: [key, subscriptionID.rawValue],
        ) else { throw StaleSubscriptionCallback() }
        let current = try armedSubscription(row)
        guard case let .requestDeadline(request, task) = current.slot.kind,
              request == notification.requestID, let deadline = current.nextFireAt,
              advance == .retire
        else { throw StaleSubscriptionCallback() }
        try recordRequestDeadline(
          parent: id, task: task, request: request, deadline: deadline, now: now, in: db,
        )
      }
      switch advance {
      case .retire:
        try db.execute(
          sql: "DELETE FROM session_subscriptions WHERE session_id = ? AND subscription_id = ?",
          arguments: [key, subscriptionID.rawValue],
        )
      case let .reschedule(next):
        try db.execute(
          sql: """
          UPDATE session_subscriptions SET next_fire_at = ?, last_fired_at = ?
          WHERE session_id = ? AND subscription_id = ?
          """,
          arguments: [SQLiteDateFormat.string(from: next), now, key, subscriptionID.rawValue],
        )
      case let .observed(marker):
        try db.execute(
          sql: """
          UPDATE session_subscriptions SET payload = COALESCE(?, payload), marker = ?, last_fired_at = ?
          WHERE session_id = ? AND subscription_id = ?
          """,
          arguments: [
            try advancedObservation.map { try Sessions.encode($0) }, marker, now, key, subscriptionID.rawValue,
          ],
        )
      }
      return enqueued
    }
    signals.post(id)
    return row
  }
}

private struct StaleSubscriptionCallback: Error {}
@_spi(SessionObservation)
public struct NonAdvancingSubscription: Error, CustomStringConvertible {
  public let description: String

  init(due: Date?, next: Date) {
    description = "reschedule did not advance stored due time \(due.map(SQLiteDateFormat.string(from:)) ?? "nil"): next \(SQLiteDateFormat.string(from: next))"
  }
}

// Re-arming after cancellation changes callback identity; transcript generation changes do not.
func observationToken(_ subscription: ArmedSubscription) -> UUID {
  observationProgress(subscription).incarnation
}

private func observationProgress(_ subscription: ArmedSubscription) -> ObservationProgress {
  subscription.slot.observationProgress ?? ObservationProgress(
    incarnation: UUID.deterministic(
      "observation-incarnation",
      subscription.session.rawValue,
      subscription.slot.id.rawValue,
    ),
    deliverySequence: 0,
  )
}
