#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.SessionDataRow
import enum SpaceCore.SessionModelRoutes
import enum SpaceCore.SessionPrompts
import struct SpaceCore.SessionRestart
import enum SpaceCore.Sessions
import enum SpaceCore.SessionStoreError
import enum SpaceCore.SQLiteDateFormat
import struct SpaceCore.SubscriptionRow
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  @discardableResult
  mutating func restart(
    _ id: SessionID,
    executor: SessionExecutor?,
    note: String?,
    modelRoute: SessionModelRoute?,
    runningWork: [String],
    armed: [SubscriptionID: Subscription]? = nil,
    uuid: () -> UUID,
  ) throws -> SessionRestart {
    let key = id.rawValue
    let nowDate = now()
    let now = SQLiteDateFormat.string(from: nowDate)
    var head = GenerationHead(
      id: uuid(), timestamp: nowDate, summary: "", snapshot: StateSnapshot(), note: note, runningWork: runningWork,
    )
    let record = try Sessions.record(key, in: db)
    try (executor ?? record.executor).requireSupported()
    guard record.lifecycle == .live else { throw SessionStoreError.restartOfArchivedSession(key) }
    let storedExecutor = try Sessions.concreteExecutor(executor ?? record.executor, route: modelRoute)
    if executor != nil || modelRoute != nil {
      let kind = storedExecutor.kind
      let config = storedExecutor.configJSON
      try db.execute(SessionDataRow.where { $0.id.eq(key) }.update { $0.executor = kind; $0.executorConfig = config })
    }
    try SessionModelRoutes.write(key, route: modelRoute, in: &db)
    let runtime = try Sessions.runtime(key, in: db)
    let queue = try recoverRestartQueue(key, tail: runtime.queueTail)
    if queue.dropped > 0 {
      let dropped = "Dropped \(queue.dropped) queued input(s) that could not be read."
      head.note = [note, dropped].compactMap(\.self).joined(separator: "\n")
    }
    let generation = runtime.generation + 1
    head.snapshot = .init(subscriptions: try armed ?? armedSlots(id).slots)
    try openGeneration(key, generation: generation)
    try Sessions.appendLines(key, generation: generation, head.lines(session: id), in: &db)
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update {
      $0.hold = "normal"
      $0.work = "no_work"
      $0.errorMessage = #bind(Optional<String>.none)
      $0.runState = "no_run"
      $0.runProgressAt = #bind(Optional<String>.none)
      $0.lastActivityAt = now
    })
    try db.execute(RestartSession.where { $0.id.eq(key) }.update { $0.runHeartbeatAt = #bind(Optional<String>.none) })
    try SessionPrompts.invalidate(key, in: &db)
    if Sessions.queueHead(key, tail: queue.tail, at: rowNow, in: db) > queue.tail { try markHasWork(key, now: rowNow) }
    return SessionRestart(generation: Int(generation), executor: try Sessions.record(key, in: db).executor)
  }

  func armedSlots(_ id: SessionID) throws -> (slots: [SubscriptionID: Subscription], handlers: Set<SubscriptionID>) {
    var slots: [SubscriptionID: Subscription] = [:]
    var handlers: Set<SubscriptionID> = []
    for row in db.rows(SubscriptionRow.of(.session(id))) {
      let slot = try ArmedSubscription(row: row).slot
      guard let subscription = slot.kind.subscription else { continue }
      slots[slot.id] = subscription
      if slot.handler != nil { handlers.insert(slot.id) }
    }
    for notice in try Sessions.pendingTimers(id.rawValue, in: db) {
      slots[notice.subscriptionID] = notice.schedule.map(Subscription.timer)
    }
    for stream in Sessions.streams(id.rawValue, in: db) {
      slots[stream.id] = .stream(stream.url)
    }
    return (slots, handlers)
  }
}

@Table("sessions")
private struct RestartSession {
  let id: String
  @Column("run_heartbeat_at") var runHeartbeatAt: String?
}
