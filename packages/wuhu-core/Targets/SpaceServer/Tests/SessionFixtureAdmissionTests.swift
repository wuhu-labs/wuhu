import Testing

@Suite(.timeLimit(.minutes(1))) struct SessionFixtureAdmissionTests {
  @Test func boundsAdmissionAndHandsReleasedCapacityToTheNextWaiter() async throws {
    let admission = SessionFixtureAdmission(capacity: 1)
    try await admission.acquire()
    let next = Task { try await admission.acquire() }
    defer { next.cancel() }
    try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
    #expect(await admission.available == 0)
    await admission.release()
    try await next.value
    #expect(await admission.available == 0)
    #expect(await admission.waitingCount == 0)
    await admission.release()
    #expect(await admission.available == 1)
  }

  @Test func cancelledWaiterDoesNotConsumeOrCreateCapacity() async throws {
    let admission = SessionFixtureAdmission(capacity: 1)
    try await admission.acquire()
    let next = Task { try await admission.acquire() }
    defer { next.cancel() }
    try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
    next.cancel()
    await #expect(throws: CancellationError.self) { try await next.value }
    #expect(await admission.available == 0)
    #expect(await admission.waitingCount == 0)
    await admission.release()
    #expect(await admission.available == 1)
  }

  @Test func cancellationRacingAdmissionReturnsItsCapacity() async throws {
    for _ in 0 ..< 100 {
      let admission = SessionFixtureAdmission(capacity: 1)
      try await admission.acquire()
      let next = Task {
        do {
          try await admission.acquire()
          await admission.release()
        } catch is CancellationError {}
      }
      defer { next.cancel() }
      try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
      await admission.release()
      next.cancel()
      try await next.value
      #expect(await admission.available == 1)
      #expect(await admission.waitingCount == 0)
    }
  }
}
