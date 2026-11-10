import JSONValue
import func MainHub.handlerInput
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceCore.ObserverAdvance
import struct SpaceCore.ObserverRows
import struct SpaceCore.ObserverSlot
import struct SpaceCore.SessionPut
import enum SpaceCore.SubscriptionOwner
import WuweiNeo
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A handler slot as a cell, a session's or a group's observer alike: its state is its `subscription_slots` row. What comes (rows main mails, an event from its stream job, its timer coming due) waits on the slot until a firing takes it; one handler job runs at a time, the input is taken only when a firing ends well, and a failed one is retried, backing off from 1 s to 5 min. Its key is `<owner kind>:<owner>:<subscription>`.
@Cell
struct ObserverCell {
  /// Main saw the slot change: armed, paused, gone, or its owner archived.
  mutating func look() throws {
    guard let slot = try rows.slot(owner, subscription), slot.subscription.status == .armed else { return stopStream() }
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
    guard let slot = try! rows.slot(owner, subscription), slot.subscription.status == .armed, slot.firing == nil,
          let due = due(slot)
    else { return nil }
    return Instant(milliseconds: Int64((due.timeIntervalSince1970 * 1000).rounded(.up)))
  }

  /// The query's rows changed: they replace whatever waits.
  mutating func observed(_ input: JSONValue, _ marker: String) throws {
    guard let slot = try rows.slot(owner, subscription), slot.subscription.marker != marker, slot.pendingMarker != marker else { return }
    try rows.pend(owner, subscription, input, marker: marker)
    try look()
  }

  /// One event, acked once a firing takes it; or the stream's end.
  mutating func streamed(_ batch: StreamBatch) throws {
    guard batch.job == streamJob, let slot = try rows.slot(owner, subscription), slot.subscription.status == .armed else {
      if batch.ending == nil { ctx.send(.stop, to: batch.job) }
      return
    }
    if let ending = batch.ending {
      if let notice = try rows.endStream(owner, subscription, reason: ending, uuid: client.uuid) { tell([notice]) }
      return
    }
    try rows.pend(owner, subscription, batch.event!.handlerInput, marker: nil)
    try look()
  }

  mutating func fired(_ job: HandlerJob.ID, _ answer: HandlerAnswer) throws {
    let slot = try rows.slot(owner, subscription)
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
    tell(try rows.finish(
      owner, subscription, firing: answer.firing, path: answer.path, kind: answer.fireTime == nil ? .spaceObservation : .timer,
      outcome: answer.outcome, advance: advance, uuid: client.uuid,
    ))
    if case .stream? = kind, case .ok = answer.outcome, slot?.firing == answer.firing { ctx.send(.acked, to: streamJob) }
    try look()
  }

  /// Starts a firing on what waits, once it is due; an owner that can no longer act ends the slot instead.
  private mutating func fire(_ slot: ObserverSlot) throws {
    guard slot.firing == nil, let input = input(slot), let due = due(slot), due <= client.dueNow() else { return }
    guard let group = slot.group else {
      try rows.retire(owner, subscription)
      return stopStream()
    }
    let firing = client.uuid()
    try rows.begin(owner, subscription, firing: firing, group: group)
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

  private mutating func stopStream() {
    guard ctx.exists(streamJob) else { return }
    ctx.send(.stop, to: streamJob)
  }

  private var owner: SubscriptionOwner { id.owner }
  private var subscription: SubscriptionID { id.subscription }
  private var streamJob: StreamJob.ID { .init(id.key) }

  private var rows: ObserverRows {
    ObserverRows(host: db.host, store: client.store)
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
