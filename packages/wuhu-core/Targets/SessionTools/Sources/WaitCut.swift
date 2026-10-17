import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import SessionDomain

/// What ends an exec or run_script call's wait before its work ends. The
/// work runs on, and its end arrives as a message.
enum WaitCut: Sendable, Equatable {
  /// The call's `wait_seconds` passed.
  case waited(Double)
  /// Something arrived for the session and its grace passed.
  case arrival

  /// Says why the call returned `running`.
  var reason: String {
    switch self {
    case let .waited(wait): "still running after \(seconds(.seconds(wait))) s"
    case .arrival: "a message arrived, so the call gave the turn back; still running"
    }
  }

  /// Whichever comes first: `wait` seconds, or the end of the grace of what
  /// waits for the session, which runs from when it arrived. Nil once the call is cancelled.
  static func first(wait: Double, arrivals: AsyncThrowingStream<[PendingArrival], any Error>) async -> WaitCut? {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    return await withTaskGroup(of: WaitCut?.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        do { try await clock.sleep(for: .seconds(wait)) } catch { return nil }
        return .waited(wait)
      }
      group.addTask { await graceElapsed(arrivals, clock: clock) ? .arrival : nil }
      while let next = await group.next() {
        if let next { return next }
        if Task.isCancelled { return nil }
      }
      return nil
    }
  }

  /// How long after something arrives the call still waits. Task-local only
  /// so tests can shorten them.
  @TaskLocal static var directGrace: Duration = .seconds(10)
  @TaskLocal static var otherGrace: Duration = .seconds(90)

  static func grace(_ urgency: ArrivalUrgency) -> Duration {
    switch urgency {
    case .direct: directGrace
    case .other: otherGrace
    }
  }

  private static func interval(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  private enum GraceEvent: Sendable {
    case pending([PendingArrival])
    case elapsed
    case unobserved
  }

  // True once the grace of something that arrived has passed, the earliest
  // end winning; false when cancelled, or when the observation ends before
  // anything arrived.
  private static func graceElapsed(_ arrivals: AsyncThrowingStream<[PendingArrival], any Error>, clock: any Clock<Duration>) async -> Bool {
    @Dependency(\.date) var date
    let (events, sink) = AsyncStream<GraceEvent>.makeStream()
    return await withTaskGroup(of: Void.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        do {
          for try await pending in arrivals { sink.yield(.pending(pending)) }
        } catch {
          Logger(label: "wuhu.tool-grace").error("could not observe the session's queue", metadata: ["error": "\(error)"])
        }
        sink.yield(.unobserved)
      }
      var soonest: Date?
      for await event in events {
        switch event {
        case let .pending(pending):
          guard let end = pending.map({ $0.arrivedAt.addingTimeInterval(interval(grace($0.urgency))) }).min(),
                soonest.map({ end < $0 }) ?? true
          else { continue }
          soonest = end
          let left = end.timeIntervalSince(date.now)
          if left <= 0 { return true }
          let remaining = Duration.seconds(left)
          group.addTask {
            do { try await clock.sleep(for: remaining) } catch { return }
            sink.yield(.elapsed)
          }
        case .elapsed:
          return true
        case .unobserved:
          if soonest == nil { return false }
        }
      }
      return false
    }
  }
}
