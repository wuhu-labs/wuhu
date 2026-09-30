import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct GRDB.DatabaseError
import Logging
import SessionDomain
@_spi(SessionObservation) import SpaceCore

public struct SubscriptionFiring: Sendable {
  let space: Space
  var log = Logger(label: "wuhu.subscription-firing")
  var observationStream: @Sendable (Space, SessionID, String) async throws -> AsyncThrowingStream<Rows, any Error> = { space, session, sql in
    let principal = try await space.principal(of: session)
    return await space.observeQuery(sql, throttle: .zero, as: principal)
  }

  var nextCronFire: @Sendable (String, Date) -> Date? = { expression, after in
    try? CronSchedule.parse(expression).next(after: after)
  }

  public init(space: Space) {
    self.space = space
  }

  public func run() async {
    @Dependency(\.continuousClock) var clock
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
          let current = registrations.map { (Arming($0.subscription, callbackID: $0.callbackID), $0.subscription) }
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
          for (arming, job) in running where !keys.contains(arming) {
            job.task.cancel()
            await job.task.value
            running[arming] = nil
          }
          for (arming, subscription) in current where running[arming] == nil {
            guard !stopped.contains(arming) else { continue }
            generation += 1
            let startedGeneration = generation
            let backoff = retries[arming] ?? 0
            running[arming] = (startedGeneration, Task {
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
    let now = date.now
    let due = subscription.nextFireAt ?? now
    switch subscription.slot.kind {
    case .observe:
      break
    case let .timer(schedule, message):
      try await fireTimer(subscription, schedule: schedule, message: message, due: due, now: now)
    case .parkReminder:
      try await firePark(subscription)
    case let .requestDeadline(request, task):
      try await fireDeadline(subscription, request: request, task: task, now: now)
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
    var snapshots = try await observationStream(space, subscription.session, sql).makeAsyncIterator()
    while !Task.isCancelled {
      let rows: Rows?
      do {
        rows = try await snapshots.next()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard invalidObservationQuery(error) else { throw error }
        log.warning("observation \(subscription.slot.id.rawValue) query failed: \(error)")
        try await notifyObservation(
          subscription,
          callbackID: callbackID,
          text: "observation \(subscription.slot.id.rawValue) failed and was cancelled: \(error)",
          advance: .retire,
        )
        return
      }
      guard let rows else { throw FiringFailure.observationStreamEnded }
      let marker = rowsMarker(rows)
      guard marker != delivered else { continue }
      try await notifyObservation(
        subscription,
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
    try await deliver(subscription, notification: notification, advance: advance)
  }

  // Only the removed contractor executor armed park rows; a leftover one
  // retires unfired, since every live session nags from its environment.
  private func firePark(_ subscription: ArmedSubscription) async throws {
    try await retire(subscription)
  }

  private func fireDeadline(
    _ subscription: ArmedSubscription,
    request: RequestID,
    task: SessionID,
    now: Date,
  ) async throws {
    let notification = SystemNotification(
      id: UUID.deterministic("deadline", subscription.session.rawValue, request.rawValue),
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
    try await deliver(subscription, notification: notification, advance: .retire)
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
    let notification = SystemNotification(
      id: UUID.deterministic(
        "timer",
        subscription.session.rawValue,
        subscription.slot.id.rawValue,
        String(due.timeIntervalSince1970),
      ),
      timestamp: now,
      kind: .timer,
      subscriptionID: subscription.slot.id,
      endsSubscription: endsSubscription,
      content: .init(text: message),
    )
    try await deliver(subscription, notification: notification, advance: advance)
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

  private func deliver(
    _ subscription: ArmedSubscription,
    notification: SystemNotification,
    advance: SessionStore.SubscriptionAdvance,
  ) async throws {
    do {
      try await space.sessions.fireSubscription(
        subscription.session,
        subscriptionID: subscription.slot.id,
        notification: notification,
        advance: advance,
      )
    } catch let error as SessionStoreError {
      switch error {
      case .archiveGraceExpired, .unknownSession:
        try await retire(subscription)
      case .unknownMessage, .unknownConversation, .replyTargetInAnotherConversation,
           .selfDirectMessage, .taskHasNoBox, .taskTakesNoHumanInput, .noParent, .notTheParent,
           .requestAlreadyOpen, .unknownRequest,
           .busyForRestart, .restartOfArchivedSession, .parentUnavailableForCreation, .unusableTitle, .tooDeep, .notInCharge, .mayNotArchive:
        throw error
      }
    }
  }

  private func retire(_ subscription: ArmedSubscription) async throws {
    try await space.sessions.cancelSubscription(
      subscription.session,
      subscriptionID: subscription.slot.id,
    )
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
  var session: SessionID
  var subscription: SubscriptionID
  var kind: SubscriptionSlot.Kind
  var nextFireAt: Date?
  var callbackID: UUID?

  init(_ armed: ArmedSubscription, callbackID: UUID?) {
    session = armed.session
    subscription = armed.slot.id
    kind = armed.slot.kind
    nextFireAt = armed.nextFireAt
    self.callbackID = callbackID
  }
}
