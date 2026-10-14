#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

extension SessionActor {
  // Nothing to deliver: the environment either nags now, or says when a park
  // reminder falls due and the actor stays loaded until then.
  func nagOrScheduleWake(_ environment: SessionEnvironment) throws -> Nag? {
    try modify {
      $0.parkWake?.task.cancel()
      $0.parkWake = nil
    }
    let now = date()
    if let nag = environment.nag(task: (try live).isTask, now: now) { return nag }
    guard let due = environment.nextTimer(now: now) else { return nil }
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
