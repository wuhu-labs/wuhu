import Clocks
import Synchronization
import TaskLifetime
import Testing

private enum Context {
  @TaskLocal static var value = "outside"
}

private actor Owner {
  let scope = TaskScope()
  var calls = 0
  func perform() async throws -> Int {
    try await scope.run("actor-work") {
      calls += 1
      return calls
    }.value
  }
}

@Test func tasksInheritContextAndActorIsolation() async throws {
  let scope = TaskScope()
  let value = try await Context.$value.withValue("inside") {
    try await scope.run("context") { Context.value }.value
  }
  #expect(value == "inside")
  #expect(try await Owner().perform() == 1)
  await scope.close()
  #expect(scope.liveTasks.isEmpty)
}

@Test func closeCancelsAndDrainsAllNamedWork() async throws {
  let scope = TaskScope()
  let (started, signal) = AsyncStream<Void>.makeStream()
  let (blocked, _) = AsyncStream<Void>.makeStream()
  let ended = Mutex(0)
  for _ in 0 ..< 2 {
    try scope.run("pump") {
      signal.yield(())
      for await _ in blocked {}
      ended.withLock { $0 += 1 }
    }
  }
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next(); _ = await iterator.next()
  #expect(scope.liveTasks == ["pump", "pump"])
  await scope.close()
  #expect(ended.withLock { $0 } == 2)
  #expect(scope.liveTasks.isEmpty)
  await scope.close()
}

@Test func scopeDrainsWhenCloseCallerIsCancelled() async throws {
  let scope = TaskScope()
  let (blocked, _) = AsyncStream<Void>.makeStream()
  let ended = Mutex(false)
  try scope.run("cleanup") {
    for await _ in blocked {}
    ended.withLock { $0 = true }
  }
  let closer = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await scope.close()
  }
  await closer.value
  #expect(ended.withLock { $0 })
}

@Test func runPreservesValuesAndFailures() async throws {
  struct Failure: Error, Equatable {}
  let scope = TaskScope()
  #expect(try await scope.run("value") { 42 }.value == 42)
  await #expect(throws: Failure.self) {
    try await scope.run("failure") { throw Failure() }.value
  }
  await scope.close()
}

@Test func deadlineUsesInjectedClockAndCancelsTheLoser() async throws {
  let clock = TestClock<Duration>()
  let (blocked, _) = AsyncStream<Void>.makeStream()
  let ended = Mutex(false)
  let call = Task {
    try await withDeadline(.seconds(5), clock: clock) {
      for await _ in blocked {}
      ended.withLock { $0 = true }
      try Task.checkCancellation()
    }
  }
  await clock.advance(by: .seconds(5))
  await #expect(throws: DeadlineExceeded.self) { try await call.value }
  #expect(ended.withLock { $0 })
}

@Test func successfulDeadlineCancelsItsTimer() async throws {
  let clock = TestClock<Duration>()
  #expect(try await withDeadline(.seconds(5), clock: clock) { 42 } == 42)
}

@Test func bestEffortIsOwnedAndDrained() async throws {
  let scope = TaskScope()
  let (started, signal) = AsyncStream<Void>.makeStream()
  let (blocked, _) = AsyncStream<Void>.makeStream()
  let ended = Mutex(false)
  scope.bestEffort("stop", within: .seconds(30)) {
    signal.yield(())
    for await _ in blocked {}
    ended.withLock { $0 = true }
  }
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next()
  await scope.close()
  #expect(ended.withLock { $0 })
}

@Test func cancelLeavesDrainingToTheParent() async throws {
  let scope = TaskScope()
  let (started, signal) = AsyncStream<Void>.makeStream()
  let (cancelled, cancellation) = AsyncStream<Void>.makeStream()
  let (released, release) = AsyncStream<Void>.makeStream()
  let gate = Task { for await _ in released {} }
  let drained = Mutex(false)
  try scope.run("noncooperative-work") {
    await withTaskCancellationHandler {
      signal.yield(())
      await gate.value
      drained.withLock { $0 = true }
    } onCancel: { cancellation.yield(()) }
  }
  var arrivals = started.makeAsyncIterator()
  _ = await arrivals.next()
  scope.cancel()
  var cancellations = cancelled.makeAsyncIterator()
  _ = await cancellations.next()
  #expect(!drained.withLock { $0 })
  #expect(scope.liveTasks == ["noncooperative-work"])
  release.finish()
  await scope.close()
  #expect(drained.withLock { $0 })
}

@Test func bestEffortDeadlineCancelsItsOperation() async throws {
  let scope = TaskScope()
  let (cancelled, signal) = AsyncStream<Void>.makeStream()
  let (blocked, _) = AsyncStream<Void>.makeStream()
  let clock = TestClock<Duration>()
  scope.bestEffort("bounded-stop", within: .seconds(5), clock: clock) {
    await withTaskCancellationHandler {
      for await _ in blocked {}
    } onCancel: { signal.yield(()) }
  }
  await clock.advance(by: .seconds(5))
  var iterator = cancelled.makeAsyncIterator()
  _ = await iterator.next()
  await scope.close()
  #expect(scope.liveTasks.isEmpty)
}

@Test func uncancellableCompletesCleanupAndPreservesTaskLocals() async throws {
  let operation = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return await Context.$value.withValue("cleanup") {
      await uncancellable("Cleanup must finish after cancellation") {
        #expect(!Task.isCancelled)
        return Context.value
      }
    }
  }
  #expect(await operation.value == "cleanup")
}

@Test func closedScopeRefusesAdmissionWithoutRunningIt() async throws {
  let scope = TaskScope()
  await scope.close()
  let ran = Mutex(false)
  #expect(throws: TaskScopeClosed.self) {
    try scope.run("refused") { ran.withLock { $0 = true } }
  }
  #expect(!ran.withLock { $0 })
}

@Test func admittedChildCanHandleNestedAdmissionDuringClose() async throws {
  let scope = TaskScope()
  let (started, signal) = AsyncStream<Void>.makeStream()
  let (released, release) = AsyncStream<Void>.makeStream()
  let gate = Task { for await _ in released {} }
  let refused = Mutex(false)
  let outer = try scope.run("accepted-stop") {
    signal.yield(())
    await gate.value
    do { try scope.run("nested-exchange") {} }
    catch { refused.withLock { $0 = true } }
  }
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next()
  let closer = Task { await scope.close() }
  // Wait until close has cancelled the accepted child before releasing it.
  while !outer.isCancelled { await Task.yield() }
  release.finish()
  await closer.value
  #expect(refused.withLock { $0 })
  #expect(scope.liveTasks.isEmpty)
}

private actor AdmissionOrder {
  private var order: [Int] = []
  func check() async throws -> [Int] {
    let scope = TaskScope()
    let first = try scope.run("first") { order.append(1) }
    let second = Task { order.append(2) }
    await first.value
    await second.value
    await scope.close()
    return order
  }
}

@Test func scopeEnqueuesItsWrapperOnTheCallersActor() async throws {
  for _ in 0 ..< 100 { #expect(try await AdmissionOrder().check() == [1, 2]) }
}

@Test func unjoinedDeadlineAnswersBeforeNoncooperativeWorkEnds() async throws {
  let scope = TaskScope()
  let clock = TestClock<Duration>()
  let (started, start) = AsyncStream<Void>.makeStream()
  let (release, released) = AsyncStream<Void>.makeStream()
  let gate = Task { for await _ in release {} }
  let completed = Mutex(false)
  let call = Task {
    try await withUnjoinedDeadline("poisoned-peer", within: .seconds(5), clock: clock, scope: scope) {
      start.finish()
      await gate.value
      completed.withLock { $0 = true }
    }
  }
  for await _ in started {}
  await clock.advance(by: .seconds(5))
  await #expect(throws: DeadlineExceeded.self) { try await call.value }
  #expect(!completed.withLock { $0 })
  #expect(scope.liveTasks.contains("poisoned-peer"))
  released.finish()
  await scope.close()
  #expect(completed.withLock { $0 })
}

@Test func unjoinedDeadlinePreservesFailuresAndRefusesClosedScope() async throws {
  struct Failure: Error, Equatable {}
  let scope = TaskScope()
  await #expect(throws: Failure.self) {
    try await withUnjoinedDeadline("failure", within: .seconds(5), clock: ContinuousClock(), scope: scope) { throw Failure() }
  }
  await scope.close()
  await #expect(throws: TaskScopeClosed.self) {
    try await withUnjoinedDeadline("refused", within: .seconds(5), clock: ContinuousClock(), scope: scope) { 42 }
  }
}
