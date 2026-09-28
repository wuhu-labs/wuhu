import Crypto
import Dependencies
import Foundation
import SessionDomain
import SpaceCore
import SpaceTools

extension SubscriptionID {
  static func observation(_ callID: ToolCallID) -> SubscriptionID {
    SubscriptionID("obs.\(callID.rawValue)")
  }

  static func timer(_ callID: ToolCallID) -> SubscriptionID {
    SubscriptionID("timer.\(callID.rawValue)")
  }
}

extension ToolExecutor {
  // Durable slots keyed by the kernel tool call id make re-registration
  // naturally idempotent (INSERT OR IGNORE), so observe/timer carry no
  // receipts: a crash-retry re-arms the same slot and rebuilds the same
  // result.
  func observe(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: ObserveArguments,
  ) async throws -> ToolResultPayload {
    let throttle: Double
    do {
      throttle = try SubscriptionArming.observationThrottle(arguments.throttleSeconds)
    } catch {
      throw ToolProblem(error.message)
    }
    // Running the query now both validates it through the sandbox and pins
    // the baseline: arming never fires on rows that already existed.
    let baseline = try await space.query(arguments.sql, as: try await space.principal(of: session))
    let subscriptionID = SubscriptionID.observation(callID)
    try await store.armSubscription(
      session,
      slot: .init(id: subscriptionID, kind: .observe(sql: arguments.sql, throttleSeconds: throttle)),
      marker: rowsMarker(baseline),
    )
    return .observe(.init(subscriptionID: subscriptionID, sql: arguments.sql))
  }

  func timer(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: TimerArguments,
  ) async throws -> ToolResultPayload {
    @Dependency(\.date) var date
    let schedule: TimerSchedule
    let nextFireAt: Date
    do {
      (schedule, nextFireAt) = try SubscriptionArming.timerSchedule(
        inSeconds: arguments.inSeconds, cron: arguments.cron, now: date.now,
      )
    } catch {
      throw ToolProblem(error.message)
    }
    let subscriptionID = SubscriptionID.timer(callID)
    try await store.armSubscription(
      session,
      slot: .init(id: subscriptionID, kind: .timer(schedule, message: arguments.message)),
      nextFireAt: nextFireAt,
    )
    return .timer(.init(subscriptionID: subscriptionID, schedule: schedule, message: arguments.message))
  }

  enum CancelKind {
    case observation
    case timer
  }

  func cancel(
    _ kind: CancelKind,
    _ session: SessionID,
    _ arguments: CancelArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    let subscriptionID = SubscriptionID(arguments.subscriptionID)
    // The fold answers only so a cancel retried after a crash, its slot
    // already deleted, stays idempotent.
    let armed = try await store.armedSubscriptions(session).first { $0.slot.id == subscriptionID }
    let standing = if let armed { armed.subscription } else { state.subscriptions[subscriptionID] }
    switch (standing, kind) {
    case (.observe, .observation), (.timer, .timer):
      break
    case (.observe, .timer):
      throw ToolProblem("\(subscriptionID.rawValue) is an observation; use cancel_observation")
    case (.timer, .observation):
      throw ToolProblem("\(subscriptionID.rawValue) is a timer; use cancel_timer")
    case (.requestDeadline, _):
      throw ToolProblem("\(subscriptionID.rawValue) is the deadline of a request you opened; it ends with the task's final report")
    case (nil, _):
      throw ToolProblem("unknown subscription: \(subscriptionID.rawValue)")
    }
    try await store.cancelSubscription(session, subscriptionID: subscriptionID)
    return switch kind {
    case .observation: .cancelObservation(.init(subscriptionID: subscriptionID))
    case .timer: .cancelTimer(.init(subscriptionID: subscriptionID))
    }
  }
}

extension ArmedSubscription {
  fileprivate var subscription: Subscription? {
    switch slot.kind {
    case let .observe(sql, _):
      return .observe(sql: sql)
    case let .timer(schedule, _):
      return .timer(schedule)
    case .requestDeadline:
      guard let nextFireAt else { preconditionFailure("a request deadline is armed with its fire time") }
      return .requestDeadline(nextFireAt)
    case .parkReminder:
      return nil
    }
  }
}

func rowsMarker(_ rows: Rows) -> String {
  let canonical = Wire.queryOutput(rows).jsonString()
  return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}
