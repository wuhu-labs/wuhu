#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

extension SessionActor {
  func nagOrScheduleWake(_ environment: SessionEnvironment) async throws -> Nag? {
    try modify {
      $0.parkWake?.task.cancel()
      $0.parkWake = nil
    }
    let now = date()
    let nag = environment.nag(task: (try live).isTask, now: now)
    let due = nag == nil ? environment.nextTimer(now: now) : nil
    if let schedule = loopConfig.scheduleWake {
      if try due != nil || live.delegatedWake {
        try await schedule(id, due)
        try modify { $0.delegatedWake = due != nil }
      }
      return nag
    }
    if let nag { return nag }
    guard let due else { return nil }
    let wait = Duration.seconds(max(0, due.timeIntervalSince(now)))
    let wake = Task { [clock] in
      guard (try? await clock.sleep(for: wait)) != nil else { return }
      self.parkWakeFired(at: due)
    }
    try modify { $0.parkWake = (due, wake) }
    return nil
  }

  private func parkWakeFired(at due: Date) {
    guard !Task.isCancelled, liveState?.parkWake?.at == due else { return }
    liveState?.parkWake = nil
    nudge()
  }
}
