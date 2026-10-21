import Crypto
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
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

extension Hub {
  // Each verb owns its idempotency: the answer is looked up and recorded in
  // the write that arms or cancels the slot, so a call that already ran, or
  // runs twice at once, acts once and gets the one answer, whether the slot
  // still stands or has since fired or been cancelled.
  nonisolated public func observe(
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
    let payload = ToolResultPayload.observe(.init(subscriptionID: subscriptionID, sql: arguments.sql))
    return try await store.armSubscription(
      session,
      slot: .init(id: subscriptionID, kind: .observe(sql: arguments.sql, throttleSeconds: throttle), handler: try handlerPath(arguments.handler)),
      marker: rowsMarker(baseline),
      answering: ToolReceipt(session: session, callID: callID, payload: payload),
    )
  }

  nonisolated public func timer(
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
    let payload = ToolResultPayload.timer(.init(subscriptionID: subscriptionID, schedule: schedule, message: arguments.message))
    return try await store.armSubscription(
      session,
      slot: .init(id: subscriptionID, kind: .timer(schedule, message: arguments.message), handler: try handlerPath(arguments.handler)),
      nextFireAt: nextFireAt,
      answering: ToolReceipt(session: session, callID: callID, payload: payload),
    )
  }

  // The subscription half of cancel(id). Only the caller's own slots are
  // looked up, so another session's id is as unknown as a made-up one. A
  // request's deadline and stall alert end with the request, never here.
  nonisolated public func cancel(_ session: SessionID, _ callID: ToolCallID, _ arguments: CancelArguments) async throws -> ToolResultPayload {
    let subscriptionID = SubscriptionID(arguments.id)
    if subscriptionID.rawValue.hasPrefix("deadline.") { throw deadlineRefusal(subscriptionID) }
    if subscriptionID.rawValue.hasPrefix("stall.") {
      throw ToolProblem("\(subscriptionID.rawValue) is the stall alert of a request you opened; it ends with the task's final report", code: "invalidArgument")
    }
    return try await store.cancelSubscription(session, subscriptionID: subscriptionID, answering: callID) { armed in
      switch armed?.kind {
      case .observe?:
        return .cancelObservation(.init(subscriptionID: subscriptionID))
      case .timer?:
        return .cancelTimer(.init(subscriptionID: subscriptionID))
      case .requestDeadline?, .requestStall?, nil:
        // Nothing remembers a subscription past its slot: one that ended (a
        // fired one-shot, a second cancel) reads like one that never was.
        throw ToolProblem("\(subscriptionID.rawValue) is not armed: it already ended, or you never had it", code: "notFound")
      }
    }
  }

  nonisolated private func deadlineRefusal(_ subscriptionID: SubscriptionID) -> ToolProblem {
    ToolProblem("\(subscriptionID.rawValue) is the deadline of a request you opened; it ends with the task's final report", code: "invalidArgument")
  }
}

private func handlerPath(_ path: String?) throws -> String? {
  guard let path else { return nil }
  let resolved = try resolveScriptModule(path.hasPrefix("/") ? "wuhu:" + path : path, from: "script")
  return path.hasPrefix("/") ? String(resolved.dropFirst("wuhu:".count)) : resolved
}
