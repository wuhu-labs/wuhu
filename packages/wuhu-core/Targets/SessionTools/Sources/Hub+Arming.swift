import Foundation
import SessionDomain
import SpaceCore

public struct ArmingProblem: Error, Sendable {
  public let message: String

  init(_ message: String) {
    self.message = message
  }
}

public enum SubscriptionArming {
  public static func timerSchedule(
    inSeconds: Double?,
    cron: String?,
    now: Date,
  ) throws(ArmingProblem) -> (schedule: TimerSchedule, nextFireAt: Date) {
    switch (inSeconds, cron) {
    case let (seconds?, nil):
      guard seconds >= 1 else { throw ArmingProblem("in_seconds must be at least 1") }
      let at = now.addingTimeInterval(seconds)
      return (.oneShot(at), at)
    case let (nil, expression?):
      let parsed: CronSchedule
      do {
        parsed = try CronSchedule.parse(expression)
      } catch {
        throw ArmingProblem(error.message)
      }
      guard let next = parsed.next(after: now) else {
        throw ArmingProblem("cron expression never fires: \(expression)")
      }
      return (.cron(expression), next)
    default:
      throw ArmingProblem("timer wants exactly one of in_seconds or cron")
    }
  }

  public static func observationThrottle(_ throttleSeconds: Double?) throws(ArmingProblem) -> Double {
    let throttle = throttleSeconds ?? 30
    guard throttle >= 1 else { throw ArmingProblem("throttle_seconds must be at least 1") }
    return throttle
  }

  public static func observationMarker(_ rows: Rows) -> String {
    rowsMarker(rows)
  }
}
