import JSONValue
import func MainHub.handlerInput
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.Arming
import struct SpaceCore.GroupCell
import enum SpaceCore.ObservationMail
import enum SpaceCore.ObservationReply
import struct SpaceCore.ObservationSlot
import enum SpaceCore.ObserverAdvance
import enum SpaceCore.ObserverRefusal
import struct SpaceCore.ObserverSlot
import struct SpaceCore.ObserverTerms
import struct SpaceCore.Rows
import struct SpaceCore.SessionPut
import struct SpaceCore.SessionStore
import enum SpaceCore.SpaceError
import enum SpaceCore.SubscriptionOwner
import struct SpaceCore.SubscriptionRow
import struct SpaceCore.SubscriptionSlot
import enum SpaceCore.SubscriptionStatus
import StructuredQueries
import Wuwei
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A session's handler slot, or a group's named observer. A firing takes pending input only on success; failures back off from one second to five minutes.
@Cell
struct ObserverCell {
  static let schema = [
    "CREATE TABLE observer_watched (\(ownerColumn), slot TEXT NOT NULL, UNIQUE (owner))",
    "CREATE TABLE observer_identity (\(ownerColumn), subscription TEXT NOT NULL, UNIQUE (owner))",
    "CREATE TABLE observer_admissions (\(ownerColumn), admitted_at REAL NOT NULL)",
  ]
  mutating func arm(_ terms: ObserverTerms, slot: SubscriptionSlot, nextFireAt: Date? = nil, marker: String? = nil) throws -> ArmedSubscription {
    guard case let .group(group) = owner else { preconditionFailure("a group arms a named observer") }
    precondition(terms.name == id.subscription.rawValue)
    guard slot.handler != nil else { throw ObserverRefusal.handlerRequired }
    guard ctx.cell(GroupCell.ID(group.rawValue)).record() != nil else { throw SpaceError.groupForbidden(group.rawValue) }
    if let standing = groupRow {
      guard standing.status == SubscriptionStatus.paused.rawValue else { throw ObserverRefusal.nameTaken(terms.name) }
      stopStream()
      try db.execute(SubscriptionRow.of(owner).where { $0.name.eq(terms.name) }.delete())
    }
    let row = try SubscriptionRow(owner: owner, slot: slot.prepared(uuid: client.uuid), name: terms.name, sessionsPerHour: terms.sessionsPerHour, nextFireAt: nextFireAt, marker: marker, armedAt: client.now())
    try db.execute(ObserverIdentity.delete())
    try db.execute(ObserverIdentity.insert { ObserverIdentity(subscription: slot.id.rawValue) })
    try db.execute(SubscriptionRow.insert { row })
    try look()
    return try ArmedSubscription(row: row)
  }

  mutating func cancelObserver() throws -> ArmedSubscription {
    guard let row = groupRow else { throw ObserverRefusal.unknownObserver(id.subscription.rawValue) }
    let armed = try ArmedSubscription(row: row)
    try db.execute(SubscriptionRow.of(owner).where { $0.name.eq(id.subscription.rawValue) }.delete())
    try pruneFirings(owner)
    stopStream()
    try reconcile()
    return armed
  }

  mutating func admit() throws -> ObserverRefusal? {
    guard let row = groupRow else { return .unknownObserver(id.subscription.rawValue) }
    let name = row.name!
    guard row.status == SubscriptionStatus.armed.rawValue else { return .paused(name) }
    let now = client.now().timeIntervalSince1970
    try db.execute(ObserverAdmission.where { $0.admittedAt.lte(now - 3600) }.delete())
    let cap = row.sessionsPerHour!
    let made = db.rows(ObserverAdmission.all.asSelect().count()).first!
    if made >= cap {
      let refusal = ObserverRefusal.atCap(name: name, sessionsPerHour: cap)
      var slot = try ArmedSubscription(row: row).slot
      slot.lastError = refusal.description
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      let payload = String(decoding: try encoder.encode(slot), as: UTF8.self)
      try db.execute(SubscriptionRow.of(owner).where { $0.name.eq(name) }.update {
        $0.payload = #bind(payload)
        $0.status = #bind(SubscriptionStatus.paused.rawValue)
      })
      try look()
      return refusal
    }
    try db.execute(ObserverAdmission.insert { ObserverAdmission(admittedAt: now) })
    return nil
  }

  private var groupRow: SubscriptionRow? {
    precondition(owner.group != nil)
    return db.rows(SubscriptionRow.of(owner).where { $0.name.eq(id.subscription.rawValue) }).first
  }

  /// Its session armed it.
  mutating func arm(_ arming: Arming) throws {
    guard case let .session(session) = owner else { return }
    try arm(session, arming, uuid: client.uuid)
    try look()
  }

  /// Its session's `cancel`: a firing in progress runs on.
  mutating func cancel() throws {
    try retire(owner, subscription)
    stopStream()
    try reconcile()
  }

  /// Its query can no longer run.
  mutating func failed(_ watched: ObservationSlot, _ reason: String) throws {
    guard try slot(owner, subscription)?.subscription.observationSlot == watched else { return }
    let text = owner.session == nil ? "observation query failed: \(reason)" : "observation \(subscription.rawValue) failed and was cancelled: \(reason)"
    try end(text)
  }

  /// Reconciles the slot and fires what is due.
  mutating func look() throws {
    try reconcile()
    guard let slot = try slot(owner, subscription), slot.subscription.status == .armed else { return stopStream() }
    if case let .stream(url, throttle) = slot.subscription.slot.kind {
      ctx.create(streamJob, params: .init(dialer: owner, session: nil, subscription: subscription, url: url, throttle: throttle, owner: id.recipient.retyped()))
    }
    try fire(slot)
  }

  /// Its timer, a throttle or a backoff ran out.
  mutating func wake() throws {
    try look()
  }

  func nextWake() -> Instant? {
    guard let slot = try! currentSlot(), slot.subscription.status == .armed, slot.firing == nil,
          let due = due(slot)
    else { return nil }
    return Instant(milliseconds: Int64((due.timeIntervalSince1970 * 1000).rounded(.up)))
  }

  /// The query's rows changed: they replace whatever waits.
  mutating func observed(_ watched: ObservationSlot, _ snapshot: Rows, _ marker: String) throws {
    guard let slot = try slot(owner, subscription), slot.subscription.observationSlot == watched,
          slot.subscription.marker != marker, slot.pendingMarker != marker else { return }
    try pend(owner, subscription, handlerInput(snapshot), marker: marker)
    try look()
  }

  /// One event, acked once a firing takes it; or the stream's end.
  mutating func streamed(_ batch: StreamBatch) throws {
    guard batch.job == streamJob, let slot = try slot(owner, subscription), slot.subscription.status == .armed else {
      if batch.ending == nil { ctx.send(.stop, to: batch.job) }
      return
    }
    if let ending = batch.ending { return try end(ending) }
    try pend(owner, subscription, batch.event!.handlerInput, marker: nil)
    try look()
  }

  mutating func fired(_ job: HandlerJob.ID, _ answer: HandlerAnswer) throws {
    let subscription = answer.subscription
    let slot = try slot(owner, subscription)
    let kind = slot?.subscription.slot.kind
    var advance = ObserverAdvance.taken(marker: answer.marker)
    if case let .timer(schedule, _)? = kind {
      switch schedule {
      case .oneShot:
        advance = .retire
      case let .cron(expression):
        let after = max(client.now(), answer.fireTime ?? client.now())
        advance = (try? CronSchedule.parse(expression).next(after: after)).map(ObserverAdvance.reschedule) ?? .retire
      }
    }
    tell(try finish(
      owner, subscription, firing: answer.firing, path: answer.path, kind: answer.fireTime == nil ? .spaceObservation : .timer,
      outcome: answer.outcome, advance: advance, uuid: client.uuid,
    ))
    if case .stream? = kind, case .ok = answer.outcome, slot?.firing == answer.firing { ctx.send(.acked, to: streamJob) }
    if slot != nil, try self.slot(owner, subscription) == nil { ended() }
    try look()
  }

  /// Starts a firing on what waits, once it is due; an owner that can no longer act ends the slot instead.
  private mutating func fire(_ slot: ObserverSlot) throws {
    guard slot.firing == nil, let input = input(slot), let due = due(slot), due <= client.dueNow() else { return }
    guard let group = slot.group else {
      try retire(owner, subscription)
      ended()
      try reconcile()
      return stopStream()
    }
    let firing = client.uuid()
    try begin(owner, subscription, firing: firing, group: group)
    ctx.create(HandlerJob.ID("\(id.key):\(firing.uuidString.lowercased())"), params: .init(
      cell: id, owner: owner, subscription: subscription, name: slot.subscription.name, group: group, firing: firing,
      path: slot.subscription.slot.handler!, input: input.json, marker: input.marker, fireTime: input.fireTime,
    ))
  }

  /// What waits, as the handler gets it: with its slot's id, the one thing that tells one use of a shared module from another.
  private func input(_ slot: ObserverSlot) -> (json: JSONValue, marker: String?, fireTime: Date?)? {
    let waiting: (json: JSONValue, marker: String?, fireTime: Date?)? = if case .timer = slot.subscription.slot.kind {
      slot.subscription.nextFireAt.map { (handlerInput(fireTime: $0), nil, $0) }
    } else {
      slot.pending.map { ($0, slot.pendingMarker, nil) }
    }
    guard let waiting, case var .object(fields) = waiting.json else { return nil }
    fields["subscription"] = .string(subscription.rawValue)
    return (.object(fields), waiting.marker, waiting.fireTime)
  }

  /// When what waits may fire: a timer at its time, anything after the backoff of a failure in a row, rows after their throttle.
  private func due(_ slot: ObserverSlot) -> Date? {
    var due: Date
    switch slot.subscription.slot.kind {
    case .timer:
      guard let next = slot.subscription.nextFireAt else { return nil }
      due = next
    case .observe, .stream, .children:
      guard slot.pending != nil else { return nil }
      due = .distantPast
    }
    guard let last = slot.subscription.lastFiredAt else { return due }
    if slot.failures > 0 {
      due = max(due, last.addingTimeInterval(Double(min(1 << min(slot.failures - 1, 9), 300))))
    } else if case let .observe(_, throttle) = slot.subscription.slot.kind {
      due = max(due, last.addingTimeInterval(throttle))
    }
    return due
  }

  private mutating func tell(_ notices: [SystemNotification]) {
    guard case let .session(session) = owner else { return }
    for notice in notices {
      ctx.send(SessionCell.ID(session.rawValue)).put(SessionPut(.notification(notice)))
    }
  }

  private mutating func end(_ reason: String) throws {
    if let notice = try end(owner, subscription, reason: reason, uuid: client.uuid) { tell([notice]) }
    try reconcile()
    ended()
  }

  /// The session lists what it armed: it hears of a slot that ended without its `cancel`.
  private mutating func ended() {
    guard case let .session(session) = owner else { return }
    ctx.send(SessionCell.ID(session.rawValue)).ended(subscription)
  }

  private mutating func stopStream() {
    guard ctx.exists(streamJob) else { return }
    ctx.send(.stop, to: streamJob)
  }

  private mutating func reconcile() throws {
    let previous = db.rows(ObserverWatched.all).first
    let slot = try currentSlot()?.subscription
    let next: ObservationSlot? = if let slot, slot.status == .armed, case .observe = slot.slot.kind { slot.observationSlot } else { nil }
    let payload = next?.key
    if previous?.slot == payload { return }
    if let previous {
      let watched = try JSONDecoder().decode(ObservationSlot.self, from: Data(previous.slot.utf8))
      ctx.send(.unwatch(watched), to: ObservationMail.recipient)
      try db.execute(ObserverWatched.delete())
    }
    if let payload {
      ctx.send(.watch(slot!.watch(recipient: id.recipient.retyped())), to: ObservationMail.recipient)
      try db.execute(ObserverWatched.insert { ObserverWatched(slot: payload) })
    }
  }

  private func currentSlot() throws -> ObserverSlot? {
    if owner.group != nil {
      guard let row = groupRow else { return nil }
      return try slot(owner, SubscriptionID(row.subscriptionID))
    }
    return try slot(owner, id.subscription)
  }

  private var owner: SubscriptionOwner { id.owner }
  private var subscription: SubscriptionID {
    switch owner {
    case .session: id.subscription
    case .group: SubscriptionID(db.rows(ObserverIdentity.all).first!.subscription)
    }
  }

  private var streamJob: StreamJob.ID {
    .init(owner.group == nil ? id.key : "\(id.key):\(subscription.rawValue)")
  }

  private var client: LoopClient {
    ctx.dependency(LoopClient.self)
  }
}

extension Address where Target == ObserverCell {
  init(_ owner: SubscriptionOwner, _ subscription: SubscriptionID) {
    switch owner {
    case let .session(session): self.init("session:\(session.rawValue):\(subscription.rawValue)")
    case let .group(group): self.init("group:\(group.rawValue):\(subscription.rawValue)")
    }
  }

  var owner: SubscriptionOwner {
    let parts = key.split(separator: ":", maxSplits: 2)
    return parts[0] == "session" ? .session(SessionID(String(parts[1]))) : .group(GroupID(rawValue: String(parts[1])))
  }

  var subscription: SubscriptionID {
    SubscriptionID(String(key.split(separator: ":", maxSplits: 2)[2]))
  }
}

@Table("observer_watched")
private struct ObserverWatched: Owned {
  let slot: String
}

@Table("observer_identity")
private struct ObserverIdentity: Owned {
  let subscription: String
}

@Table("observer_admissions")
private struct ObserverAdmission: Owned {
  @Column("admitted_at") let admittedAt: Double
}
