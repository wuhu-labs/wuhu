import Testing

@Suite(.timeLimit(.minutes(1))) struct SessionFixtureAdmissionTests {
  @Test func boundsAdmissionAndHandsReleasedCapacityToTheNextWaiter() async throws {
    let admission = SessionFixtureAdmission(capacity: 1)
    let first = try await admission.acquire("first", within: .seconds(30))
    let next = Task { try await admission.acquire("next", within: .seconds(30)) }
    defer { next.cancel() }
    try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
    #expect(await admission.available == 0)
    await admission.release(first)
    let second = try await next.value
    #expect(await admission.available == 0)
    #expect(await admission.waitingCount == 0)
    await admission.release(second)
    #expect(await admission.available == 1)
  }

  @Test func cancelledWaiterDoesNotConsumeOrCreateCapacity() async throws {
    let admission = SessionFixtureAdmission(capacity: 1)
    let first = try await admission.acquire("first", within: .seconds(30))
    let next = Task { try await admission.acquire("next", within: .seconds(30)) }
    defer { next.cancel() }
    try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
    next.cancel()
    await #expect(throws: CancellationError.self) { try await next.value }
    #expect(await admission.available == 0)
    #expect(await admission.waitingCount == 0)
    await admission.release(first)
    #expect(await admission.available == 1)
  }

  @Test func cancellationRacingAdmissionReturnsItsCapacity() async throws {
    for _ in 0 ..< 100 {
      let admission = SessionFixtureAdmission(capacity: 1)
      let first = try await admission.acquire("first", within: .seconds(30))
      let next = Task {
        do {
          await admission.release(try await admission.acquire("next", within: .seconds(30)))
        } catch is CancellationError {}
      }
      defer { next.cancel() }
      try await until("fixture waits for capacity") { await admission.waitingCount == 1 }
      await admission.release(first)
      next.cancel()
      try await next.value
      #expect(await admission.available == 1)
      #expect(await admission.waitingCount == 0)
    }
  }

  @Test func aWaiterPastTheBoundNamesItselfAndEveryHolder() async throws {
    let admission = SessionFixtureAdmission(capacity: 2)
    let first = try await admission.acquire("leaked", within: .seconds(30))
    let second = try await admission.acquire("slow", within: .seconds(30))
    do {
      _ = try await admission.acquire("starved", within: .milliseconds(50))
      Issue.record("A full admission must not admit past its bound")
    } catch let timeout as SessionFixtureAdmission.Timeout {
      #expect(timeout.waiter == "starved")
      #expect(timeout.holders.map(\.name) == ["leaked", "slow"])
    }
    #expect(await admission.waitingCount == 0)
    await admission.release(first)
    await admission.release(second)
    #expect(await admission.available == 2)
  }

  @Test func aFixtureUnderAPlainTimeLimitIsRefused() async throws {
    await #expect(throws: SessionFixtureUnderTimeLimit.self) { try await withSessionDeps {} }
  }
}

@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct SessionFixtureTraitTests {
  @Test func fixturesRunInsideTheTraitsAdmission() async throws {
    #expect(SessionFixtureAdmission.isAdmitted)
    try await withSessionDeps { #expect(SessionFixtureAdmission.isAdmitted) }
  }
}

private let nestedAdmission = SessionFixtureAdmission(capacity: 1)

@Suite(.sessionFixtures(timeLimit: .minutes(1), admission: nestedAdmission, bound: .seconds(1))) struct NestedSessionFixtureTraitTests {
  @Suite struct Inner {
    @Test(.sessionFixtures(timeLimit: .minutes(1), admission: nestedAdmission, bound: .seconds(1)))
    func nestedScopesShareTheOutermostSlot() async throws {
      #expect(SessionFixtureAdmission.isAdmitted)
      #expect(await nestedAdmission.available == 0)
      #expect(await nestedAdmission.waitingCount == 0)
    }
  }
}
