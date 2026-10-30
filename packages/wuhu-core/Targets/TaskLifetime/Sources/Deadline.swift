import protocol Clocks.NonsendingClock

public struct DeadlineExceeded: Error, Equatable, Sendable {
  public init() {}
}

public func withDeadline<Value: Sendable, C: NonsendingClock>(
  _ duration: Duration, clock: C, isolation: isolated (any Actor)? = #isolation,
  operation: @escaping @Sendable () async throws -> Value,
) async throws -> Value where C.Duration == Duration {
  let deadline = clock.now.advanced(by: duration)
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await clock.sleep(until: deadline, tolerance: nil, isolation: isolation)
      throw DeadlineExceeded()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
