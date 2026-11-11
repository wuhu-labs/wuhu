#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID

/// A handler slot as its observer cell finds it.
public struct ObserverSlot: Sendable {
  public let subscription: ArmedSubscription
  /// The input no firing has taken yet, and the rows marker it carries.
  public let pending: JSONValue?
  public let pendingMarker: String?
  /// Nil once its owner can no longer act: an archived session, a removed group.
  public let group: GroupID?
  /// Its firings that failed since the last one that did not.
  public let failures: Int

  /// The firing in progress.
  public var firing: UUID? { subscription.slot.firing }
}

/// What a firing that ended well does to its slot.
public enum ObserverAdvance: Hashable, Sendable {
  /// The input was taken: rows up to `marker`, or, with none, a stream's event.
  case taken(marker: String?)
  case reschedule(Date)
  case retire
}

public enum HandlerOutcome: Hashable, Sendable, Codable {
  case ok(wakes: [String])
  case failed(String)
}

/// The writes an observer cell makes to its slot, in a transaction its caller holds: the space writer's own connection, as wuwei's shared backend lends it.
public struct ObserverRows {
  let db: Database
  let store: SessionStore

  public init(host: AnyObject?, store: SessionStore) {
    guard let db = host as? Database else { preconditionFailure("observer rows need the space writer's connection") }
    self.init(db: db, store: store)
  }

  init(db: Database, store: SessionStore) {
    self.db = db
    self.store = store
  }

  private var now: Date { store.dateGen.now }

  public func slot(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws -> ObserverSlot? {
    guard let row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return nil }
    return ObserverSlot(
      subscription: try store.armedSubscription(row), pending: row.pending, pendingMarker: row.pendingMarker,
      group: try SessionStore.actingGroup(of: owner, in: db), failures: try failures(owner, id),
    )
  }

  /// The slot a session armed, as its observer's row; one that stands is left as it is.
  public func arm(_ session: SessionID, _ arming: Arming, uuid: () -> UUID) throws {
    try store.armSubscription(
      session.rawValue, slot: store.prepared(arming.slot, uuid: uuid), name: arming.name, nextFireAt: arming.nextFireAt, marker: arming.marker,
      now: SQLiteDateFormat.string(from: now), in: db,
    )
  }

  /// `input` is what the next firing takes, in place of anything pending.
  public func pend(_ owner: SubscriptionOwner, _ id: SubscriptionID, _ input: JSONValue, marker: String?) throws {
    guard var row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return }
    row.pending = input
    row.pendingMarker = marker
    try SubscriptionRow.save(row, in: db)
  }

  /// The slot names `firing` as its own, and the log has it running.
  public func begin(_ owner: SubscriptionOwner, _ id: SubscriptionID, firing: UUID, group: GroupID) throws {
    guard var row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { preconditionFailure("a firing begins on its slot") }
    let at = SQLiteDateFormat.string(from: now)
    var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
    slot.firing = firing
    row.payload = try Sessions.encode(slot)
    row.lastFiredAt = at
    try SubscriptionRow.save(row, in: db)
    try FiringRow.insert {
      FiringRow(
        id: firing.uuidString.lowercased(), ownerKind: owner.kind, owner: owner.key, subscription: id.rawValue,
        name: row.name, grp: group.rawValue, at: at, outcome: FiringOutcome.running.rawValue, error: nil, effects: nil,
      )
    }.execute(db)
  }

  /// Ends a firing: logs it with what it made and, while its owner can act, gives a session its wakes and its first failure in a row. A slot that still names the firing takes `advance` on success, the error on failure; one that went meanwhile (cancelled from inside the firing or not) marks the wakes as its last. Returns the notices a session owner is due.
  public func finish(
    _ owner: SubscriptionOwner, _ id: SubscriptionID, firing: UUID, path: String, kind: SystemNotification.Kind,
    outcome: HandlerOutcome, advance: ObserverAdvance, uuid: () -> UUID,
  ) throws -> [SystemNotification] {
    let firingKey = firing.uuidString.lowercased()
    let row = try SubscriptionRow.find(owner, id.rawValue, in: db)
    let slot = try row.map { try Sessions.decode(SubscriptionSlot.self, from: $0.payload) }
    let mine = slot?.firing == firing
    guard try SessionStore.actingGroup(of: owner, in: db) != nil else {
      if mine, var row, var slot {
        slot.firing = nil
        row.payload = try Sessions.encode(slot)
        try SubscriptionRow.save(row, in: db)
      }
      try SessionStore.endFiring(firingKey, .cancelled, in: db)
      return []
    }
    let streak = try failures(owner, id)
    var texts: [String] = []
    var last = !mine
    if mine, var current = row, var stored = slot {
      switch outcome {
      case let .ok(wakes):
        texts = wakes
        if current.status == SubscriptionStatus.armed.rawValue { stored.lastError = nil }
        switch advance {
        case .retire:
          last = true
        case let .reschedule(next):
          current.nextFireAt = SQLiteDateFormat.string(from: next)
        case let .taken(marker?):
          current.marker = marker
          if current.pendingMarker == marker { (current.pending, current.pendingMarker) = (nil, nil) }
        case .taken(nil):
          (current.pending, current.pendingMarker) = (nil, nil)
        }
      case let .failed(error):
        if streak == 0 { texts = ["handler \(path) for \(id.rawValue) failed: \(error)"] }
        stored.lastError = error
      }
      if case .ok = outcome, advance == .retire {
        try SubscriptionRow.delete(owner, id.rawValue, in: db)
      } else {
        stored.firing = nil
        current.payload = try Sessions.encode(stored)
        try SubscriptionRow.save(current, in: db)
      }
    } else if case let .ok(wakes) = outcome {
      texts = wakes
    }
    switch outcome {
    case .ok: try SessionStore.endFiring(firingKey, .ok, in: db)
    case let .failed(error): try SessionStore.endFiring(firingKey, .failed, error: error, in: db)
    }
    try SessionStore.pruneFirings(now: now, in: db)
    guard case .session = owner else { return [] }
    return texts.map { SystemNotification(id: uuid(), timestamp: now, kind: kind, subscriptionID: id, endsSubscription: last, content: .init(text: $0)) }
  }

  /// Its source refused to go on (a stream, a query that can no longer run): the slot of a session ends, and the notice it is due is returned; a group's observer pauses with the reason.
  public func end(_ owner: SubscriptionOwner, _ id: SubscriptionID, reason: String, uuid: () -> UUID) throws -> SystemNotification? {
    guard let row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return nil }
    switch owner {
    case .session:
      try SubscriptionRow.delete(owner, id.rawValue, in: db)
      return SystemNotification(id: uuid(), timestamp: now, kind: .spaceObservation, subscriptionID: id, endsSubscription: true, content: .init(text: reason))
    case .group:
      try SessionStore.pause(row, error: reason, in: db)
      return nil
    }
  }

  public func retire(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws {
    try SubscriptionRow.delete(owner, id.rawValue, in: db)
  }

  private func failures(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws -> Int {
    try String.fetchAll(
      db,
      sql: """
      SELECT outcome FROM subscription_firings WHERE owner_kind = ? AND owner = ? AND subscription = ? AND outcome IN ('ok', 'failed')
      ORDER BY at DESC, rowid DESC LIMIT 16
      """,
      arguments: [owner.kind, owner.key, id.rawValue],
    ).prefix { $0 == FiringOutcome.failed.rawValue }.count
  }
}
