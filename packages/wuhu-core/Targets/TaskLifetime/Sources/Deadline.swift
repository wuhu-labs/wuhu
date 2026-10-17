public struct DeadlineExceeded: Error, Equatable, Sendable {
  public init() {}
}

public func withDeadline<Value: Sendable, C: Clock>(
  _ duration: Duration, clock: C,
  operation: @escaping @Sendable () async throws -> Value,
) async throws -> Value where C.Duration == Duration {
  let deadline = clock.now.advanced(by: duration)
  return try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await clock.sleep(until: deadline, tolerance: nil)
      throw DeadlineExceeded()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
