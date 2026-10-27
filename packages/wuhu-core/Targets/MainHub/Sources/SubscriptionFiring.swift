import Dependencies
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct GRDB.DatabaseError
import Logging
import ServerTelemetry
import SessionDomain
@_spi(SessionObservation) import SpaceCore

public struct SubscriptionFiring: Sendable {
  let space: Space
  var log = Logger(label: "wuhu.subscription-firing")
  var observationStream: @Sendable (Space, Principal, String) async throws -> AsyncThrowingStream<Rows, any Error> = { space, principal, sql in
    await space.observeQuery(sql, throttle: .zero, as: principal)
  }

  var nextCronFire: @Sendable (String, Date) -> Date? = { expression, after in
    try? CronSchedule.parse(expression).next(after: after)
  }

  private let worker: any Worker

  public init(space: Space, worker: any Worker) {
    self.space = space
    self.worker = worker
  }

  public func run() async {
    @Dependency(\.continuousClock) var clock
    do {
      try await space.sessions.interruptFirings()
    } catch {
      log.warning("the firings the last run left running were not ended: \(error)")
    }
    while !Task.isCancelled {
      do {
        try await runRegistry()
      } catch is CancellationError {
        return
      } catch {
        log.warning("the subscription registry ended; re-subscribing: \(error)")
        do {
          try await clock.sleep(for: .seconds(1))
        } catch {
          return
        }
      }
    }
  }

  private func runRegistry() async throws {
    let taskScope = TaskScope()
    let (events, post) = AsyncStream.makeStream(of: RegistryEvent.self)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          for try await _ in space.sessions.observeArmedSubscriptions() {
            post.yield(.changed)
          }
          if Task.isCancelled {
            post.finish()
          } else {
            post.yield(.failed(FiringFailure.registryStreamEnded))
          }
        } catch {
          post.yield(.failed(error))
        }
      }
      var running: [Arming: (generation: Int, task: Task<Void, Never>)] = [:]
      var stopped: Set<Arming> = []
      var retries: [Arming: Int] = [:]
      var generation = 0
      var failure: (any Error)?
      do {
        for await event in events {
          if Task.isCancelled { break }
          var completion: (Arming, Result<Void, any Error>)?
          switch event {
          case .changed:
            break
          case let .finished(arming, completedGeneration, outcome):
            guard running[arming]?.generation == completedGeneration else { continue }
            let completed = running.removeValue(forKey: arming)!
            await completed.task.value
            completion = (arming, outcome)
          case let .failed(error):
            throw error
          }
          let registrations = try await space.sessions.subscriptionRegistrations()
          let current = registrations.map { (Arming($0.subscription, callbackID: $0.callbackID, orphaned: $0.orphaned), $0.subscription) }
          let keys = Set(current.map(\.0))
          stopped.formIntersection(keys)
          retries = retries.filter { keys.contains($0.key) }
          if let (arming, outcome) = completion {
            switch outcome {
            case .failure(let error) where error is NonAdvancingSubscription:
              if keys.contains(arming) { stopped.insert(arming) }
            case .failure:
              if keys.contains(arming) { retries[arming] = min(max(1, (retries[arming] ?? 0) * 2), 60) }
            case .success where keys.contains(arming):
              if case .timer(.cron, _) = arming.kind {
                log.error("recurring timer \(arming.subscription.rawValue) did not advance its stored due time after a successful fire; stopped")
                stopped.insert(arming)
              } else {
                log.warning("subscription \(arming.subscription.rawValue) ended with its stored arming unchanged; retrying")
                retries[arming] = min(max(1, (retries[arming] ?? 0) * 2), 60)
              }
            case .success:
              break
            }
          }
          // A gone slot's firing is stopped, not waited for: its end is a
          // stale generation, and the scope joins it on the way out.
          for (arming, job) in running where !keys.contains(arming) {
            job.task.cancel()
            running[arming] = nil
          }
          for (arming, subscription) in current where running[arming] == nil {
            guard !stopped.contains(arming) else { continue }
            generation += 1
            let startedGeneration = generation
            let backoff = retries[arming] ?? 0
            running[arming] = (startedGeneration, try taskScope.run("subscription-firing") {
              let outcome: Result<Void, any Error>
              do {
                @Dependency(\.continuousClock) var clock
                if backoff > 0 { try await clock.sleep(for: .seconds(backoff)) }
                try Task.checkCancellation()
                try await run(subscription, callbackID: arming.callbackID)
                outcome = .success(())
              } catch {
                if error is NonAdvancingSubscription {
                  log.error("subscription \(arming.subscription.rawValue) stopped: \(error)")
                } else if !(error is CancellationError) {
                  log.warning("subscription \(arming.subscription.rawValue) failed: \(error)")
                }
                outcome = .failure(error)
              }
              post.yield(.finished(arming, startedGeneration, outcome))
            })
          }
        }
      } catch {
        failure = error
      }
      group.cancelAll()
      post.finish()
      for job in running.values { job.task.cancel() }
      for job in running.values { await job.task.value }
      await taskScope.close()
      if let failure { throw failure }
    }
  }

  private func run(_ subscription: ArmedSubscription, callbackID: UUID?) async throws {
    if case let .observe(sql, throttleSeconds) = subscription.slot.kind {
      guard let callbackID else { throw FiringFailure.missingObservationCallback }
      try await runObservation(subscription, callbackID: callbackID, sql: sql, throttleSeconds: throttleSeconds)
      return
    }
    try await sleep(until: subscription.nextFireAt)
    @Dependency(\.date) var date
    guard try await retireIfOrphaned(subscription) == false else { return }
    let now = date.now
    let due = subscription.nextFireAt ?? now
    switch subscription.slot.kind {
    case .observe:
      break
    case let .timer(schedule, message):
      try await fireTimer(subscription, schedule: schedule, message: message, due: due, now: now)
    case let .requestDeadline(request, task):
      guard let parent = try await wakes(subscription, orPause: "a request deadline belongs to a session") else { return }
      try await fireDeadline(subscription, to: parent, request: request, task: task, now: now)
    case .requestStall:
      guard let parent = try await wakes(subscription, orPause: "a request stall belongs to a session") else { return }
      try await space.sessions.checkRequestStall(
        parent, subscriptionID: subscription.slot.id, now: now, liveScripts: Set(await worker.activity().scripts.values),
      )
    }
  }

  private func runObservation(
    _ subscription: ArmedSubscription,
    callbackID: UUID,
    sql: String,
    throttleSeconds: Double,
  ) async throws {
    @Dependency(\.continuousClock) var clock
    var delivered = subscription.marker
    var snapshots = try await observationStream(space, principal(of: subscription), sql).makeAsyncIterator()
    while !Task.isCancelled {
      let rows: Rows?
      do {
        rows = try await snapshots.next()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard invalidObservationQuery(error) else { throw error }
        log.warning("observation \(subscription.slot.id.rawValue) query failed: \(error)")
        guard let session = try await wakes(subscription, orPause: "observation query failed: \(error)") else { return }
        try await notifyObservation(
          subscription,
          to: session,
          callbackID: callbackID,
          text: "observation \(subscription.slot.id.rawValue) failed and was cancelled: \(error)",
          advance: .retire,
        )
        return
      }
      guard let rows else { throw FiringFailure.observationStreamEnded }
      let marker = rowsMarker(rows)
      guard marker != delivered else { continue }
      guard try await retireIfOrphaned(subscription) == false else { return }
      if subscription.slot.handler != nil {
        try await fireHandler(subscription, rows: rows, fireTime: nil, advance: .observed(marker: marker), marker: marker)
        delivered = marker
        try await clock.sleep(for: .seconds(throttleSeconds))
        continue
      }
      guard let session = try await wakes(subscription, orPause: "a group observer runs a handler") else { return }
      try await notifyObservation(
        subscription,
        to: session,
        callbackID: callbackID,
        text: "observed change for \(sql):\n" + renderedRows(rows),
        advance: .observed(marker: marker),
      )
      delivered = marker
      try await clock.sleep(for: .seconds(throttleSeconds))
    }
    throw CancellationError()
  }

  private func notifyObservation(
    _ subscription: ArmedSubscription,
    to session: SessionID,
    callbackID: UUID,
    text: String,
    advance: SessionStore.SubscriptionAdvance,
  ) async throws {
    @Dependency(\.date) var date
    let notification = SystemNotification(
      id: callbackID,
      timestamp: date.now,
      kind: .spaceObservation,
      subscriptionID: subscription.slot.id,
      endsSubscription: advance == .retire,
      content: .init(text: text),
    )
    try await deliver(subscription, to: session, notification: notification, advance: advance)
  }

  private func fireDeadline(
    _ subscription: ArmedSubscription,
    to parent: SessionID,
    request: RequestID,
    task: SessionID,
    now: Date,
  ) async throws {
    let notification = SystemNotification(
      id: UUID.deterministic("deadline", parent.rawValue, request.rawValue),
      timestamp: now,
      kind: .requestDeadline,
      subscriptionID: subscription.slot.id,
      endsSubscription: true,
      requestID: request,
      content: .init(text: """
      Request \(request.rawValue) on task \(task.rawValue) passed its deadline with no final report. \
      Decide: re-request, kill it, or replace it.
      """),
    )
    try await deliver(subscription, to: parent, notification: notification, advance: .retire)
  }

  private func fireTimer(
    _ subscription: ArmedSubscription,
    schedule: TimerSchedule,
    message: String,
    due: Date,
    now: Date,
  ) async throws {
    let advance: SessionStore.SubscriptionAdvance
    let endsSubscription: Bool
    switch schedule {
    case .oneShot:
      advance = .retire
      endsSubscription = true
    case let .cron(expression):
      guard let next = nextCronFire(expression, max(now, due)) else {
        try await retire(subscription)
        return
      }
      advance = .reschedule(next)
      endsSubscription = false
    }
    if subscription.slot.handler != nil {
      try await fireHandler(subscription, rows: nil, fireTime: due, advance: advance)
      return
    }
    guard let session = try await wakes(subscription, orPause: "a group timer runs a handler") else { return }
    let notification = SystemNotification(
      id: UUID.deterministic(
        "timer",
        session.rawValue,
        subscription.slot.id.rawValue,
        String(due.timeIntervalSince1970),
      ),
      timestamp: now,
      kind: .timer,
      subscriptionID: subscription.slot.id,
      endsSubscription: endsSubscription,
      content: .init(text: message),
    )
    try await deliver(subscription, to: session, notification: notification, advance: advance)
  }

  // A failed firing's input stands: the same rows or fire time go again,
  // backing off, until the handler takes them or the slot goes.
  private func fireHandler(
    _ subscription: ArmedSubscription,
    rows: Rows?,
    fireTime: Date?,
    advance: SessionStore.SubscriptionAdvance,
    marker: String? = nil,
  ) async throws {
    @Dependency(\.continuousClock) var clock
    var backoff = 0
    while try await !fireHandlerOnce(subscription, rows: rows, fireTime: fireTime, advance: advance, marker: marker) {
      backoff = min(max(1, backoff * 2), 300)
      try await clock.sleep(for: .seconds(backoff))
    }
  }

  private func fireHandlerOnce(
    _ subscription: ArmedSubscription,
    rows: Rows?,
    fireTime: Date?,
    advance: SessionStore.SubscriptionAdvance,
    marker: String?,
  ) async throws -> Bool {
    try Task.checkCancellation()
    if try await retireIfOrphaned(subscription) { return true }
    guard let path = subscription.slot.handler, let incarnation = subscription.slot.handlerIncarnation,
          let attempt = try await space.sessions.beginSubscriptionHandler(
            subscription.owner, subscriptionID: subscription.slot.id, incarnation: incarnation, marker: marker,
          )
    else { throw CancellationError() }
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    func notification(_ text: String) -> SystemNotification {
      SystemNotification(
        id: uuid(), timestamp: date.now, kind: rows == nil ? .timer : .spaceObservation,
        subscriptionID: subscription.slot.id, content: .init(text: text),
      )
    }
    let runner: ScriptHandlerInvocation.Runner = switch attempt.owner {
    case let .session(id): .session(id)
    case let .group(group): .observer(Observer(group: group, name: attempt.name!, firing: attempt.firing))
    }
    let span = ServerSpan(.firing, session: attempt.owner.session?.rawValue, group: attempt.owner.group?.rawValue)
    var traced: [SpanAttribute: String] = [.subscription: subscription.slot.id.rawValue, .firing: attempt.firing, .kind: rows == nil ? "timer" : "observe"]
    traced[.observer] = attempt.owner.group == nil ? nil : attempt.name
    let result: ScriptHandlerResult
    do {
      result = try await ServerTracing.$context.withValue(span.context) {
        try await worker.fire(.init(
          id: attempt.attemptID, path: path, runner: runner, input: rows.map(ScriptHandlerInvocation.Input.rows) ?? .timer(fireTime!),
          stateJSON: attempt.stateJSON,
        ))
      }
      try Task.checkCancellation()
      traced[.outcome] = "ok"
      span.finish(traced)
    } catch is CancellationError {
      traced[.outcome] = "cancelled"
      span.finish(traced)
      try? await uncancellable("Log the cancelled firing") { try await space.sessions.cancelFiring(attempt) }
      throw CancellationError()
    } catch {
      traced[.outcome] = "error"
      span.finish(traced)
      guard try await space.sessions.finishSubscriptionHandler(
        attempt, result: .failure(
          error: "\(error)", notification: notification("handler \(path) for \(subscription.slot.id.rawValue) failed: \(error)"),
        ),
      ) else { throw CancellationError() }
      return false
    }
    var wakes = result.wakes.map(notification)
    if advance == .retire {
      for index in wakes.indices { wakes[index].endsSubscription = true }
    }
    guard try await space.sessions.finishSubscriptionHandler(
      attempt, result: .success(stateJSON: result.stateJSON, advance: advance, wakes: wakes),
    ) else { throw CancellationError() }
    return true
  }

  private func principal(of subscription: ArmedSubscription) async throws -> Principal {
    switch subscription.owner {
    case let .session(id): try await space.principal(of: id)
    case let .group(group): Observer(group: group, name: subscription.name!, firing: nil).principal
    }
  }

  private func sleep(until due: Date?) async throws {
    try Task.checkCancellation()
    guard let due else { throw FiringFailure.missingDueTime }
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    let delay = due.timeIntervalSince(date.now)
    if delay > 0 { try await clock.sleep(for: .seconds(delay)) }
    try Task.checkCancellation()
  }

  /// The session a notifying slot wakes. A group's slot wakes no one: it
  /// pauses instead, `error` its last error.
  private func wakes(_ subscription: ArmedSubscription, orPause error: @autoclosure () -> String) async throws -> SessionID? {
    switch subscription.owner {
    case let .session(id):
      return id
    case let .group(group):
      try await space.sessions.pauseObserver(group, subscriptionID: subscription.slot.id, error: error())
      return nil
    }
  }

  private func deliver(
    _ subscription: ArmedSubscription,
    to session: SessionID,
    notification: SystemNotification,
    advance: SessionStore.SubscriptionAdvance,
  ) async throws {
    do {
      try await space.sessions.fireSubscription(
        session,
        subscriptionID: subscription.slot.id,
        notification: notification,
        advance: advance,
      )
    } catch let error as SessionStoreError {
      switch error {
      case .archiveGraceExpired, .unknownSession:
        try await retire(subscription)
      case .modelRouteInvalid, .unknownMessage, .unknownConversation, .replyTargetInAnotherConversation,
           .selfDirectMessage, .humanAgentDirectMessage, .taskHasNoBox, .taskTakesNoHumanInput, .notTheParent,
           .requestAlreadyOpen, .unknownRequest, .reportRefused,
           .busyForRestart, .requestDeadlineWithoutFireDate, .restartOfArchivedSession, .parentUnavailableForCreation, .unusableTitle, .tooDeep, .notInCharge, .mayNotArchive:
        throw error
      }
    }
  }

  private func retireIfOrphaned(_ subscription: ArmedSubscription) async throws -> Bool {
    try await space.sessions.retireOrphanedSubscription(subscription.owner, subscriptionID: subscription.slot.id)
  }

  private func retire(_ subscription: ArmedSubscription) async throws {
    try await space.sessions.cancelSubscription(subscription.owner, subscriptionID: subscription.slot.id)
  }
}

private func invalidObservationQuery(_ error: any Error) -> Bool {
  if let error = error as? DatabaseError {
    return error.resultCode == .SQLITE_ERROR || error.resultCode == .SQLITE_MISUSE
  }
  guard let error = error as? SpaceError else { return false }
  switch error {
  case .queryNotReadOnly, .queryForbiddenTable, .queryResultTooLarge, .unknownRelation:
    return true
  default:
    return false
  }
}

private enum FiringFailure: Error {
  case registryStreamEnded
  case observationStreamEnded
  case missingObservationCallback
  case missingDueTime
}

private enum RegistryEvent: Sendable {
  case changed
  case finished(Arming, Int, Result<Void, any Error>)
  case failed(any Error)
}

private struct Arming: Hashable, Sendable {
  var owner: SubscriptionOwner
  var subscription: SubscriptionID
  var kind: SubscriptionSlot.Kind
  var nextFireAt: Date?
  var callbackID: UUID?
  var handlerIncarnation: UUID?
  var orphaned: Bool

  init(_ armed: ArmedSubscription, callbackID: UUID?, orphaned: Bool) {
    owner = armed.owner
    subscription = armed.slot.id
    kind = armed.slot.kind
    nextFireAt = armed.nextFireAt
    self.callbackID = callbackID
    handlerIncarnation = armed.slot.handlerIncarnation
    self.orphaned = orphaned
  }
}
