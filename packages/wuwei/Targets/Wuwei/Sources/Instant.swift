/// Wall-clock milliseconds since 1970. Leases and wake times are compared across processes, so the runtime's time is the wall clock, or the simulation's stand-in for it.
public struct Instant: Comparable, Hashable, Sendable, Codable {
  public var milliseconds: Int64

  public init(milliseconds: Int64) {
    self.milliseconds = milliseconds
  }

  public static func < (lhs: Instant, rhs: Instant) -> Bool {
    lhs.milliseconds < rhs.milliseconds
  }

  public static func + (lhs: Instant, rhs: Duration) -> Instant {
    Instant(milliseconds: lhs.milliseconds + rhs.milliseconds)
  }

  public static func - (lhs: Instant, rhs: Instant) -> Duration {
    .milliseconds(lhs.milliseconds - rhs.milliseconds)
  }
}

extension Duration {
  var milliseconds: Int64 {
    components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
  }
}
