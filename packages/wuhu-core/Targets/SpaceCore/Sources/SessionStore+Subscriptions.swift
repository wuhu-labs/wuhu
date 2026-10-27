import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries

struct ObservationProgress: Hashable, Sendable, Codable {
  var incarnation: UUID
  var deliverySequence: Int
}

public struct SubscriptionSlot: Hashable, Sendable, Codable {
  public enum Kind: Hashable, Sendable, Codable {
    case observe(sql: String, throttleSeconds: Double)
    case timer(TimerSchedule, message: String)
    case requestDeadline(request: RequestID, task: SessionID)
    case requestStall(RequestStall)
  }

  public var id: SubscriptionID
  public var kind: Kind
  public var handler: String?
  public var handlerIncarnation: UUID?
  public var handlerStateJSON: String?
  public var lastError: String?
  var handlerFailed: Bool?
  var handlerAttemptID: UUID?
  var observationProgress: ObservationProgress?

  public init(id: SubscriptionID, kind: Kind, handler: String? = nil) {
    self.id = id
    self.kind = kind
    self.handler = handler
  }
}

public struct ArmedSubscription: Hashable, Sendable {
  public var owner: SubscriptionOwner
  public var name: String?
  public var status: SubscriptionStatus
  public var sessionsPerHour: Int?
  public var slot: SubscriptionSlot
  public var nextFireAt: Date?
  public var marker: String?
  public var lastFiredAt: Date?
  var armedAt: Date
}

/// A group observer's terms: its name is unique in the group, and it may
/// create at most `sessionsPerHour` sessions in any hour.
public struct ObserverTerms: Hashable, Sendable {
  public static let defaultSessionsPerHour = 10

  public let name: String
  public let sessionsPerHour: Int

  public init(name: String, sessionsPerHour: Int = Self.defaultSessionsPerHour) throws(ObserverRefusal) {
    guard name.utf8.count <= 64, let first = name.first, first.isLowercase || first.isNumber,
          name.allSatisfy({ ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" })
    else { throw .invalidName(name) }
    guard sessionsPerHour >= 1 else { throw .invalidCap(sessionsPerHour) }
    self.name = name
    self.sessionsPerHour = sessionsPerHour
  }
}

public enum ObserverRefusal: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidName(String)
  case invalidCap(Int)
  case nameTaken(String)
  case handlerRequired
  case unknownObserver(String)
  /// The observer made its hour's sessions and is paused until armed again.
  case atCap(name: String, sessionsPerHour: Int)
  case paused(String)

  public var code: String {
    switch self {
    case .invalidName, .invalidCap, .handlerRequired: "invalidArgument"
    case .nameTaken: "conflict"
    case .unknownObserver: "notFound"
    case .atCap, .paused: "observerPaused"
    }
  }

  public var description: String {
    switch self {
    case let .invalidName(name): "observer name \(name) is not a slug: lowercase letters, digits and hyphens, at most 64"
    case let .invalidCap(cap): "sessions_per_hour must be at least 1, not \(cap)"
    case let .nameTaken(name): "observer \(name) is armed in this group; cancel it first"
    case .handlerRequired: "a group observer runs a handler: name its module"
    case let .unknownObserver(name): "no observer \(name) in this group"
    case let .atCap(name, cap): "observer \(name) created \(cap) sessions in the last hour and is paused; arm it again to resume"
    case let .paused(name): "observer \(name) is paused; arm it again to resume"
    }
  }
}

extension SessionStore {
  // Re-arming an existing subscription id is a crash-retry: the original slot
  // (and its firing progress) stands, and the returned record is the stored
  // slot's truth, never an echo of the new arguments.
  @discardableResult
  public func armSubscription(
    _ id: SessionID,
    slot: SubscriptionSlot,
    name: String? = nil,
    nextFireAt: Date? = nil,
    marker: String? = nil,
  ) async throws -> ArmedSubscription {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let prepared = prepared(slot)
    return try await writer.write { db in
      try self.armSubscription(key, slot: prepared, name: name, nextFireAt: nextFireAt, marker: marker, now: now, in: db)
    }
  }

  // The arm as a tool call's effect: the call's answer is looked up and
  // recorded in the write that arms, so a call already answered (an earlier
  // run, or an overlapping twin of this one) gets that answer and arms
  // nothing, whether its slot still stands or has since fired or been
  // cancelled.
  public func armSubscription(
    _ id: SessionID,
    slot: SubscriptionSlot,
    name: String? = nil,
    nextFireAt: Date? = nil,
    marker: String? = nil,
    answering receipt: ToolReceipt,
  ) async throws -> ToolResultPayload {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let prepared = prepared(slot)
    return try await writer.write { db in
      if let recorded = try receipt.recorded(in: db) { return recorded }
      try self.armSubscription(key, slot: prepared, name: name, nextFireAt: nextFireAt, marker: marker, now: now, in: db)
      try receipt.record(now: now, in: db)
      return receipt.payload
    }
  }

  /// Arms a group's observer under its name. A paused observer of that name
  /// is armed again with these terms; an armed one refuses.
  @discardableResult
  public func armObserver(
    _ group: GroupID,
    _ terms: ObserverTerms,
    slot: SubscriptionSlot,
    nextFireAt: Date? = nil,
    marker: String? = nil,
  ) async throws -> ArmedSubscription {
    guard slot.handler != nil else { throw ObserverRefusal.handlerRequired }
    let owner = SubscriptionOwner.group(group)
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let prepared = prepared(slot)
    return try await writer.write { db in
      guard try Self.actingGroup(of: owner, in: db) != nil else { throw SpaceError.groupForbidden(group.rawValue) }
      if let standing = try SubscriptionRow.of(owner).where({ $0.name.eq(terms.name) }).fetchOne(db) {
        guard standing.status == SubscriptionStatus.paused.rawValue else { throw ObserverRefusal.nameTaken(terms.name) }
        try SubscriptionRow.delete(owner, standing.subscriptionID, in: db)
      }
      let row = SubscriptionRow(
        ownerKind: owner.kind, owner: owner.key, subscriptionID: prepared.id.rawValue, name: terms.name,
        sessionsPerHour: terms.sessionsPerHour, payload: try Sessions.encode(prepared),
        nextFireAt: nextFireAt.map(SQLiteDateFormat.string(from:)), marker: marker, lastFiredAt: nil, armedAt: now,
      )
      try SubscriptionRow.insert { row }.execute(db)
      return try self.armedSubscription(row)
    }
  }

  /// Ends a group's observer, named; what it made stands.
  @discardableResult
  public func cancelObserver(_ group: GroupID, name: String) async throws -> ArmedSubscription {
    let owner = SubscriptionOwner.group(group)
    return try await writer.write { db in
      guard let row = try SubscriptionRow.of(owner).where({ $0.name.eq(name) }).fetchOne(db) else {
        throw ObserverRefusal.unknownObserver(name)
      }
      try SubscriptionRow.delete(owner, row.subscriptionID, in: db)
      return try self.armedSubscription(row)
    }
  }

  public func observers(_ group: GroupID) async throws -> [ArmedSubscription] {
    try await writer.read { db in
      try SubscriptionRow.of(.group(group)).order { $0.name }.fetchAll(db).map(self.armedSubscription)
    }
  }

  // Whether an observer's firing may create one more session, in the write
  // that creates it. At its hourly cap the observer pauses, the refusal its
  // last error; the refusal is returned so the pause commits.
  static func admit(_ observer: Observer, now: Date, in db: Database) throws -> ObserverRefusal? {
    guard let row = try SubscriptionRow.of(.group(observer.group)).where({ $0.name.eq(observer.name) }).fetchOne(db),
          let cap = row.sessionsPerHour
    else { return .unknownObserver(observer.name) }
    guard row.status == SubscriptionStatus.armed.rawValue else { return .paused(observer.name) }
    let since = SQLiteDateFormat.string(from: now.addingTimeInterval(-3600))
    let made = try Int.fetchOne(
      db, sql: "SELECT count(*) FROM sessions WHERE created_by = ? AND created_at > ?", arguments: [observer.member, since],
    ) ?? 0
    guard made >= cap else { return nil }
    let refusal = ObserverRefusal.atCap(name: observer.name, sessionsPerHour: cap)
    try pause(row, error: refusal.description, in: db)
    return refusal
  }

  /// Stops a group's observer firing until it is armed again, `error` its last error.
  public func pauseObserver(_ group: GroupID, subscriptionID: SubscriptionID, error: String) async throws {
    try await writer.write { db in
      guard let row = try SubscriptionRow.find(.group(group), subscriptionID.rawValue, in: db) else { return }
      try Self.pause(row, error: error, in: db)
    }
  }

  private static func pause(_ row: SubscriptionRow, error: String, in db: Database) throws {
    var row = row
    var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
    slot.lastError = error
    row.payload = try Sessions.encode(slot)
    row.status = SubscriptionStatus.paused.rawValue
    try SubscriptionRow.save(row, in: db)
  }

  // The slot as it is stored: an observation gets its incarnation, a handler
  // a fresh one. A request's deadline and stall slots need neither.
  private func prepared(_ slot: SubscriptionSlot) -> SubscriptionSlot {
    @Dependency(\.uuid) var uuid
    var inserted = slot
    if case .observe = inserted.kind, inserted.observationProgress == nil {
      inserted.observationProgress = ObservationProgress(incarnation: uuid(), deliverySequence: 0)
    }
    if inserted.handler != nil {
      inserted.handlerIncarnation = uuid()
      inserted.handlerStateJSON = nil
      inserted.lastError = nil
      inserted.handlerFailed = nil
      inserted.handlerAttemptID = nil
    }
    return inserted
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

  static func deleteSubscription(_ key: String, _ subscriptionID: SubscriptionID, in db: Database) throws {
    try SubscriptionRow.delete(.session(SessionID(key)), subscriptionID.rawValue, in: db)
  }

  public func cancelSubscription(_ owner: SubscriptionOwner, subscriptionID: SubscriptionID) async throws {
    try await writer.write { db in try SubscriptionRow.delete(owner, subscriptionID.rawValue, in: db) }
  }

  // The cancel as a tool call's effect. `answer` sees the slot as stored (nil
  // when there is none) and says what the call returns, or throws why it
  // cannot; the lookup, the delete and the answer's receipt are one write, so
  // a call already answered (an earlier run, or an overlapping twin of this
  // one) gets that answer, never a refusal for the slot its twin removed.
  public func cancelSubscription(
    _ id: SessionID,
    subscriptionID: SubscriptionID,
    answering callID: ToolCallID,
    _ answer: @escaping @Sendable (SubscriptionSlot?) throws -> ToolResultPayload,
  ) async throws -> ToolResultPayload {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      if let recorded = try Sessions.receipt(key, toolCallID: callID.rawValue, in: db) { return recorded }
      let stored = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db).map { try self.armedSubscription($0).slot }
      let payload = try answer(stored)
      try Self.deleteSubscription(key, subscriptionID, in: db)
      try ToolReceipt(session: id, callID: callID, payload: payload).record(now: now, in: db)
      return payload
    }
  }

  /// Ends a slot whose owner can no longer act: an archived session, a
  /// removed group.
  @discardableResult
  public func retireOrphanedSubscription(_ owner: SubscriptionOwner, subscriptionID: SubscriptionID) async throws -> Bool {
    try await writer.write { db in
      guard try Self.actingGroup(of: owner, in: db) == nil,
            try SubscriptionRow.find(owner, subscriptionID.rawValue, in: db) != nil
      else { return false }
      try SubscriptionRow.delete(owner, subscriptionID.rawValue, in: db)
      return true
    }
  }

  public func armedSubscriptions() async throws -> [ArmedSubscription] {
    try await writer.read { db in
      try SubscriptionRow.order { ($0.ownerKind, $0.owner, $0.subscriptionID) }.fetchAll(db).map(armedSubscription)
    }
  }

  public func armedSubscription(_ owner: SubscriptionOwner, _ subscriptionID: SubscriptionID) async throws -> ArmedSubscription? {
    try await writer.read { db in try SubscriptionRow.find(owner, subscriptionID.rawValue, in: db).map(self.armedSubscription) }
  }

  // A paused observer is not registered: nothing fires it until it is armed again.
  @_spi(SessionObservation)
  public func subscriptionRegistrations() async throws -> [(subscription: ArmedSubscription, callbackID: UUID?, orphaned: Bool)] {
    try await writer.read { db in try subscriptionRegistrations(in: db) }
  }

  @_spi(SessionObservation)
  public func observeArmedSubscriptions()
    -> some AsyncSequence<[(subscription: ArmedSubscription, callbackID: UUID?, orphaned: Bool)], any Error> & Sendable
  {
    ValueObservation
      .tracking { db in try subscriptionRegistrations(in: db) }
      .values(in: writer, bufferingPolicy: .bufferingNewest(1))
  }

  private func subscriptionRegistrations(in db: Database) throws -> [(subscription: ArmedSubscription, callbackID: UUID?, orphaned: Bool)] {
    try SubscriptionRow.where { $0.status.eq(SubscriptionStatus.armed.rawValue) }
      .order { ($0.ownerKind, $0.owner, $0.subscriptionID) }.fetchAll(db).map { row in
        let subscription = try armedSubscription(row)
        let orphaned = try Self.actingGroup(of: subscription.owner, in: db) == nil
        guard case .observe = subscription.slot.kind else { return (subscription, nil, orphaned) }
        return (subscription, observationToken(subscription), orphaned)
      }
  }

  public func armedSubscriptions(_ id: SessionID) async throws -> [ArmedSubscription] {
    try await writer.read { db in
      try SubscriptionRow.of(.session(id)).order { $0.subscriptionID }.fetchAll(db).map(armedSubscription)
    }
  }

  func armedSubscription(_ row: SubscriptionRow) throws -> ArmedSubscription {
    guard let status = SubscriptionStatus(rawValue: row.status) else { preconditionFailure("subscription_slots.status is checked: \(row.status)") }
    return ArmedSubscription(
      owner: row.subscriptionOwner,
      name: row.name,
      status: status,
      sessionsPerHour: row.sessionsPerHour,
      slot: try Sessions.decode(SubscriptionSlot.self, from: row.payload),
      nextFireAt: try row.nextFireAt.map(SQLiteDateFormat.date(from:)),
      marker: row.marker,
      lastFiredAt: try row.lastFiredAt.map(SQLiteDateFormat.date(from:)),
      armedAt: try SQLiteDateFormat.date(from: row.armedAt),
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
        guard let row = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db) else { throw StaleSubscriptionCallback() }
        let due = try armedSubscription(row).nextFireAt
        guard let due, SQLiteDateFormat.string(from: next) > SQLiteDateFormat.string(from: due)
        else { throw NonAdvancingSubscription(due: due, next: next) }
      }
      var delivered = notification
      var advancedObservation: SubscriptionSlot?
      if notification.kind == .spaceObservation {
        guard let row = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db) else { throw StaleSubscriptionCallback() }
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
        guard let row = try SubscriptionRow.find(key, subscriptionID.rawValue, in: db) else { throw StaleSubscriptionCallback() }
        let current = try armedSubscription(row)
        guard case let .requestDeadline(request, task) = current.slot.kind,
              request == notification.requestID, let deadline = current.nextFireAt,
              advance == .retire
        else { throw StaleSubscriptionCallback() }
        try recordRequestDeadline(
          parent: id, task: task, request: request, deadline: deadline, now: now, in: db,
        )
      }
      let slot = SubscriptionRow.of(.session(id)).where { $0.subscriptionID.eq(subscriptionID.rawValue) }
      switch advance {
      case .retire:
        try Self.deleteSubscription(key, subscriptionID, in: db)
      case let .reschedule(next):
        try slot.update {
          $0.nextFireAt = #bind(SQLiteDateFormat.string(from: next))
          $0.lastFiredAt = #bind(now)
        }.execute(db)
      case let .observed(marker):
        let payload = try advancedObservation.map { try Sessions.encode($0) }
        try slot.update {
          if let payload { $0.payload = #bind(payload) }
          $0.marker = #bind(marker)
          $0.lastFiredAt = #bind(now)
        }.execute(db)
      }
      return enqueued
    }
    signals.post(id)
    return row
  }
}

/// A session handler subscription's default name: its module's file name.
func handlerName(_ path: String) -> String {
  let file = path.split(separator: "/").last.map(String.init) ?? path
  guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
  return String(file[..<dot])
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
      subscription.owner.key,
      subscription.slot.id.rawValue,
    ),
    deliverySequence: 0,
  )
}
