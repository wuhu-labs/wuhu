import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import SessionDomain
@_spi(SessionObservation) import SpaceCore

public struct SubscriptionFiring: Sendable {
  let space: Space

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
        Logger(label: "wuhu.subscription-firing")
          .warning("the subscription registry ended; re-subscribing: \(error)")
        do {
          try await clock.sleep(for: .seconds(1))
        } catch {
          return
        }
      }
    }
  }

  private func runRegistry() async throws {
    var running: [Arming: Task<Void, Never>] = [:]
    defer {
      for task in running.values { task.cancel() }
    }

    for try await registrations in space.sessions.observeArmedSubscriptions() {
      let current = registrations.map { (Arming($0.subscription, callbackID: $0.callbackID), $0) }
      var live: [Arming: Task<Void, Never>] = [:]
      for (arming, _) in current { live[arming] = running.removeValue(forKey: arming) }
      for superseded in running.values { superseded.cancel() }
      for (arming, registration) in current where live[arming] == nil {
        live[arming] = Task { await run(registration.subscription, callbackID: registration.callbackID) }
      }
      running = live
    }
  }

  private func run(_ subscription: ArmedSubscription, callbackID: UUID?) async {
    if case let .observe(sql, throttleSeconds) = subscription.slot.kind {
      guard let callbackID else { return }
      await runObservation(subscription, callbackID: callbackID, sql: sql, throttleSeconds: throttleSeconds)
      return
    }
    guard await sleep(until: subscription.nextFireAt) else { return }
    @Dependency(\.date) var date
    let now = date.now
    let due = subscription.nextFireAt ?? now
    switch subscription.slot.kind {
    case .observe:
      break
    case let .timer(schedule, message):
      await fireTimer(subscription, schedule: schedule, message: message, due: due, now: now)
    case .parkReminder:
      await firePark(subscription)
    case let .requestDeadline(request, task):
      await fireDeadline(subscription, request: request, task: task, due: due, now: now)
    }
  }

  private func runObservation(
    _ subscription: ArmedSubscription,
    callbackID: UUID,
    sql: String,
    throttleSeconds: Double,
  ) async {
    @Dependency(\.continuousClock) var clock
    var delivered = subscription.marker
    do {
      // The stream keeps only the newest snapshot, so what the throttle window
      // superseded is gone: a delivery carries the state as it stands, never a
      // queue of the states it passed through.
      let principal = try await space.principal(of: subscription.session)
      for try await rows in await space.observeQuery(sql, throttle: .zero, as: principal) {
        let marker = rowsMarker(rows)
        guard marker != delivered else { continue }
        await notifyObservation(
          subscription,
          callbackID: callbackID,
          text: "observed change for \(sql):\n" + renderedRows(rows),
          advance: .observed(marker: marker),
        )
        delivered = marker
        try await clock.sleep(for: .seconds(throttleSeconds))
      }
    } catch is CancellationError {
    } catch {
      await notifyObservation(
        subscription,
        callbackID: callbackID,
        text: "observation \(subscription.slot.id.rawValue) failed and was cancelled: \(error)",
        advance: .retire,
      )
    }
  }

  private func notifyObservation(
    _ subscription: ArmedSubscription,
    callbackID: UUID,
    text: String,
    advance: SessionStore.SubscriptionAdvance,
  ) async {
    @Dependency(\.date) var date
    let notification = SystemNotification(
      id: callbackID,
      timestamp: date.now,
      kind: .spaceObservation,
      subscriptionID: subscription.slot.id,
      endsSubscription: advance == .retire,
      content: .init(text: text),
    )
    await deliver(subscription, notification: notification, advance: advance)
  }

  // Only the removed contractor executor armed park rows; a leftover one
  // retires unfired, since every live session nags from its environment.
  private func firePark(_ subscription: ArmedSubscription) async {
    await retire(subscription)
  }

  private func fireDeadline(
    _ subscription: ArmedSubscription,
    request: RequestID,
    task: SessionID,
    due: Date,
    now: Date,
  ) async {
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
    await deliver(subscription, notification: notification, advance: .retire)
    try? await space.sessions.recordRequestDeadline(
      parent: subscription.session, task: task, request: request, deadline: due,
    )
  }

  private func fireTimer(
    _ subscription: ArmedSubscription,
    schedule: TimerSchedule,
    message: String,
    due: Date,
    now: Date,
  ) async {
    let advance: SessionStore.SubscriptionAdvance
    let endsSubscription: Bool
    switch schedule {
    case .oneShot:
      advance = .retire
      endsSubscription = true
    case let .cron(expression):
      guard let cron = try? CronSchedule.parse(expression), let next = cron.next(after: now) else {
        await retire(subscription)
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
    await deliver(subscription, notification: notification, advance: advance)
  }

  private func sleep(until due: Date?) async -> Bool {
    guard !Task.isCancelled, let due else { return false }
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date) var date
    let delay = due.timeIntervalSince(date.now)
    if delay <= 0 { return true }
    do {
      try await clock.sleep(for: .seconds(delay))
      return !Task.isCancelled
    } catch {
      return false
    }
  }

  private func deliver(
    _ subscription: ArmedSubscription,
    notification: SystemNotification,
    advance: SessionStore.SubscriptionAdvance,
  ) async {
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
        await retire(subscription)
      case .unknownMessage, .unknownConversation, .replyTargetInAnotherConversation,
           .selfDirectMessage, .taskHasNoBox, .taskTakesNoHumanInput, .noParent, .notTheParent,
           .requestAlreadyOpen, .unknownRequest,
           .busyForRestart, .restartOfArchivedSession, .unusableTitle, .tooDeep, .notInCharge, .mayNotArchive:
        break
      }
    } catch {}
  }

  private func retire(_ subscription: ArmedSubscription) async {
    try? await space.sessions.cancelSubscription(
      subscription.session,
      subscriptionID: subscription.slot.id,
    )
  }
}

// The identity of a running firing task. Marker and fire timestamps move under
// it on every delivery and are deliberately absent: keying on those would cost
// a fresh observation per notification. A re-arm mints a new callback id, and
// that is a different job.
private struct Arming: Hashable {
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
