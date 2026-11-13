#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID

struct ObservationProgress: Hashable, Sendable, Codable {
  var incarnation: UUID
  var deliverySequence: Int
}

public struct SubscriptionSlot: Hashable, Sendable, Codable {
  public enum Kind: Hashable, Sendable, Codable {
    case observe(sql: String, throttleSeconds: Double)
    case stream(url: URL, throttleSeconds: Double)
    case timer(TimerSchedule, message: String)
    /// Its owner's live children that errored or were interrupted: armed with
    /// the first live child, gone with the last, and never listed.
    case children
  }

  public var id: SubscriptionID
  public var kind: Kind
  public var handler: String?
  public var handlerIncarnation: UUID?
  public var lastError: String?
  /// The handler firing in progress: its observer cell started it and has not taken its answer.
  var firing: UUID?
  var observationProgress: ObservationProgress?

  public init(id: SubscriptionID, kind: Kind, handler: String? = nil) {
    self.id = id
    self.kind = kind
    self.handler = handler
  }

  public static let childrenID = SubscriptionID("children")

  public static func childrenQuery(_ parent: SessionID) -> String {
    """
    SELECT id, title, COALESCE(error_message, '') AS error
    FROM sessions WHERE parent = '\(parent.rawValue.replacing("'", with: "''"))' AND lifecycle = 'live' AND work = 'errored' ORDER BY id
    """
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
    case let .atCap(name, cap): "observer \(name) admitted \(cap) session creations in the last hour and is paused; arm it again to resume"
    case let .paused(name): "observer \(name) is paused; arm it again to resume"
    }
  }
}

extension SessionStore {
  public func observers(_ group: GroupID) async throws -> [ArmedSubscription] {
    try space.cell.observers(group)
  }

  public func armedSubscriptions() async throws -> [ArmedSubscription] {
    try space.cell.armedSubscriptions()
  }

  func prepared(_ slot: SubscriptionSlot, uuid: () -> UUID) -> SubscriptionSlot {
    slot.prepared(uuid: uuid)
  }

  func armedSubscription(_ row: SubscriptionRow) throws -> ArmedSubscription {
    try ArmedSubscription(row: row)
  }
}

extension SubscriptionSlot {
  public static func children(_ parent: SessionID, at now: Date) -> Self {
    var slot = Self(id: childrenID, kind: .children)
    slot.observationProgress = ObservationProgress(incarnation: UUID.deterministic("children", parent.rawValue, SQLiteDateFormat.string(from: now)), deliverySequence: 0)
    return slot
  }

  public func prepared(uuid: () -> UUID) -> SubscriptionSlot {
    var inserted = self
    if inserted.kind.observes, inserted.observationProgress == nil {
      inserted.observationProgress = ObservationProgress(incarnation: uuid(), deliverySequence: 0)
    }
    if inserted.handler != nil {
      inserted.handlerIncarnation = uuid()
      inserted.lastError = nil
      inserted.firing = nil
    }
    return inserted
  }
}

extension ArmedSubscription {
  public init(row: SubscriptionRow) throws {
    guard let status = SubscriptionStatus(rawValue: row.status) else { preconditionFailure("subscription_slots.status is checked: \(row.status)") }
    self.init(
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
}

extension SubscriptionSlot.Kind {
  /// The slot as its session lists it; the children watch is never listed.
  public var subscription: Subscription? {
    switch self {
    case let .observe(sql, _): .observe(sql: sql)
    case let .stream(url, _): .stream(url)
    case let .timer(schedule, _): .timer(schedule)
    case .children: nil
    }
  }

  /// Whether it watches a source (a query, a stream) rather than a clock.
  var observes: Bool {
    switch self {
    case .observe, .stream, .children: true
    case .timer: false
    }
  }
}

/// A session handler subscription's default name: its module's file name.
func handlerName(_ path: String) -> String {
  let file = path.split(separator: "/").last.map(String.init) ?? path
  guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
  return String(file[..<dot])
}

// Re-arming after cancellation changes callback identity; transcript generation changes do not.
func observationToken(_ subscription: ArmedSubscription) -> UUID {
  observationProgress(subscription).incarnation
}

func observationProgress(_ subscription: ArmedSubscription) -> ObservationProgress {
  subscription.slot.observationProgress ?? ObservationProgress(
    incarnation: UUID.deterministic(
      "observation-incarnation",
      subscription.owner.key,
      subscription.slot.id.rawValue,
    ),
    deliverySequence: 0,
  )
}
