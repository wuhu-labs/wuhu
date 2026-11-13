#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.Arming
import enum SpaceCore.FiringOutcome
import struct SpaceCore.FiringRow
import enum SpaceCore.HandlerOutcome
import enum SpaceCore.ObserverAdvance
import struct SpaceCore.ObserverSlot
import struct SpaceCore.RevisionAttribution
import struct SpaceCore.SessionDataRow
import enum SpaceCore.Sessions
import struct SpaceCore.SessionStore
import enum SpaceCore.SQLiteDateFormat
import enum SpaceCore.SubscriptionOwner
import struct SpaceCore.SubscriptionRow
import struct SpaceCore.SubscriptionSlot
import enum SpaceCore.SubscriptionStatus
import StructuredQueries
import Wuwei
import WuweiQueries

extension ObserverCell {
  private var now: Date { ctx.dependency(LoopClient.self).now() }

  func slot(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws -> ObserverSlot? {
    guard let row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return nil }
    return ObserverSlot(
      subscription: try ArmedSubscription(row: row), pending: row.pending, pendingMarker: row.pendingMarker,
      group: try SessionStore.actingGroup(of: owner, in: db), failures: try failures(owner, id),
    )
  }

  mutating func arm(_ session: SessionID, _ arming: Arming, uuid: () -> UUID) throws {
    let row = try SubscriptionRow(owner: .session(session), slot: arming.slot.prepared(uuid: uuid), name: arming.name, nextFireAt: arming.nextFireAt, marker: arming.marker, armedAt: now)
    try db.execute(SubscriptionRow.insert { row } onConflict: { ($0.ownerKind, $0.owner, $0.subscriptionID) })
  }

  mutating func pend(_ owner: SubscriptionOwner, _ id: SubscriptionID, _ input: JSONValue, marker: String?) throws {
    guard var row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return }
    row.pending = input
    row.pendingMarker = marker
    try SubscriptionRow.save(row, in: &db)
  }

  mutating func begin(_ owner: SubscriptionOwner, _ id: SubscriptionID, firing: UUID, group: GroupID) throws {
    guard var row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { preconditionFailure("a firing begins on its slot") }
    let at = SQLiteDateFormat.string(from: now)
    var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
    slot.firing = firing
    row.payload = try Sessions.encode(slot)
    row.lastFiredAt = at
    try SubscriptionRow.save(row, in: &db)
    try db.execute(FiringRow.insert {
      FiringRow(
        id: firing.uuidString.lowercased(), ownerKind: owner.kind, owner: owner.key, subscription: id.rawValue,
        name: row.name, grp: group.rawValue, at: at, outcome: FiringOutcome.running.rawValue, error: nil, effects: nil,
      )
    })
  }

  mutating func finish(
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
        try SubscriptionRow.save(row, in: &db)
      }
      try endFiring(firingKey, .cancelled)
      try pruneFirings(owner)
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
        try SubscriptionRow.delete(owner, id.rawValue, in: &db)
      } else {
        stored.firing = nil
        current.payload = try Sessions.encode(stored)
        try SubscriptionRow.save(current, in: &db)
      }
    } else if case let .ok(wakes) = outcome {
      texts = wakes
    }
    switch outcome {
    case .ok: try endFiring(firingKey, .ok)
    case let .failed(error): try endFiring(firingKey, .failed, error: error)
    }
    try pruneFirings(owner)
    guard case .session = owner else { return [] }
    return texts.map { SystemNotification(id: uuid(), timestamp: now, kind: kind, subscriptionID: id, endsSubscription: last, content: .init(text: $0)) }
  }

  mutating func end(_ owner: SubscriptionOwner, _ id: SubscriptionID, reason: String, uuid: () -> UUID) throws -> SystemNotification? {
    guard let row = try SubscriptionRow.find(owner, id.rawValue, in: db) else { return nil }
    switch owner {
    case .session:
      try SubscriptionRow.delete(owner, id.rawValue, in: &db)
      try pruneFirings(owner)
      return SystemNotification(id: uuid(), timestamp: now, kind: .spaceObservation, subscriptionID: id, endsSubscription: true, content: .init(text: reason))
    case .group:
      try pause(row, error: reason)
      return nil
    }
  }

  mutating func retire(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws {
    try SubscriptionRow.delete(owner, id.rawValue, in: &db)
    try pruneFirings(owner)
  }

  private func failures(_ owner: SubscriptionOwner, _ id: SubscriptionID) throws -> Int {
    db.rows(FiringRow.where {
      $0.ownerKind.eq(owner.kind) && $0.owner.eq(owner.key) && $0.subscription.eq(id.rawValue)
        && $0.outcome.in([FiringOutcome.ok.rawValue, FiringOutcome.failed.rawValue])
    }
    .order { ($0.at.desc(), #sql("rowid", as: Int64.self).desc()) }
    .limit(16)
    .select { $0.outcome })
      .prefix { $0 == FiringOutcome.failed.rawValue }.count
  }

  mutating func endFiring(_ id: String, _ outcome: FiringOutcome, error: String? = nil) throws {
    var effects: [String: [String]] = [:]
    let sessions = db.rows(SessionDataRow.where { $0.firing.eq(id) }.select { $0.id })
    let requests = db.rows(FiringRequest.where { $0.firing.eq(id) }.select { $0.id })
    let messages = db.rows(FiringMessage.where { $0.firing.eq(id) }.select { $0.id })
    let revisions = db.rows(FiringRevision.where { $0.via.eq(RevisionAttribution.firingVia(id)) }.select { $0.group + "/" + #sql("CAST(\($0.rev) AS TEXT)", as: String.self) })
    for (kind, ids) in [("sessions", sessions), ("requests", requests), ("messages", messages), ("revisions", revisions)] where !ids.isEmpty { effects[kind] = ids }
    let encoded = effects.isEmpty ? nil : try Sessions.encode(effects)
    try db.execute(FiringRow.where { $0.id.eq(id) && $0.outcome.eq(FiringOutcome.running.rawValue) }.update {
      $0.outcome = #bind(outcome.rawValue)
      $0.error = #bind(error)
      $0.effects = #bind(encoded)
    })
  }

  mutating func pruneFirings(_ owner: SubscriptionOwner) throws {
    let cutoff = SQLiteDateFormat.string(from: now.addingTimeInterval(-7 * 24 * 60 * 60))
    try db.execute(FiringRow.where {
      $0.ownerKind.eq(owner.kind) && $0.owner.eq(owner.key)
        && $0.effects.is(nil) && $0.at.lt(cutoff) && $0.outcome.neq(FiringOutcome.running.rawValue)
    }.delete())
  }

  mutating func pause(_ row: SubscriptionRow, error: String) throws {
    var row = row
    var slot = try Sessions.decode(SubscriptionSlot.self, from: row.payload)
    slot.lastError = error
    row.payload = try Sessions.encode(slot)
    row.status = SubscriptionStatus.paused.rawValue
    try SubscriptionRow.save(row, in: &db)
  }
}

@Table("requests")
private struct FiringRequest {
  let id: String
  let firing: String?
}

@Table("messages")
private struct FiringMessage {
  let id: String
  let firing: String?
}

@Table("revision_actors")
private struct FiringRevision {
  @Column("grp") let group: String
  let rev: Int64
  let via: String?
}
