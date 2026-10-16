#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Dependencies
import Testing
@testable import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct WorkerOwnerTransactionTests {
  @Test(arguments: [false, true]) func failedDrainAutomaticallyRollsBack(cancel: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let gate = WorkerOwnerTransactions()
      let entered = AsyncStream<Void>.makeStream(), held = AsyncStream<Void>.makeStream()
      defer { entered.continuation.finish(); held.continuation.finish() }
      let active = Task {
        try await gate.run {
          entered.continuation.yield(())
          for await _ in held.stream {}
        }
      }
      var iterator = entered.stream.makeAsyncIterator()
      _ = await iterator.next()
      let token = UUID()
      let pause = Task { try await gate.pause(token, drainTimeout: .seconds(2), waitTimeout: .seconds(5)) }
      try await until { await gate.pausedToken == token }
      let blocked = Task { try await gate.run { 42 } }
      try await until { await gate.waitingCount == 2 }
      if cancel { pause.cancel() } else { await clock.advance(by: .seconds(2)) }
      if cancel { await #expect(throws: CancellationError.self) { try await pause.value } }
      else { await #expect(throws: timeout) { try await pause.value } }
      #expect(try await blocked.value == 42)
      #expect(await gate.pausedToken == nil)
      #expect(try await gate.resume(token) == false)
      held.continuation.finish()
      try await active.value
      try await gate.pause(UUID(), drainTimeout: .seconds(2), waitTimeout: .seconds(5))
      await gate.close()
    }
  }

  @Test func expiredFenceFailsWaitersButOnlyExplicitResumeReopens() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let gate = WorkerOwnerTransactions(), token = UUID()
      try await gate.pause(token, drainTimeout: .seconds(2), waitTimeout: .seconds(5))
      let blocked = Task { try await gate.run { Issue.record("Expired fence admitted an effect") } }
      try await until { await gate.waitingCount == 1 }
      await clock.advance(by: .seconds(5))
      await #expect(throws: timeout) { try await blocked.value }
      await #expect(throws: timeout) { try await gate.run { true } }
      await #expect(throws: timeout) { try await gate.requirePaused(token) }
      try await gate.requirePaused(token, acceptingExpired: true)
      await #expect(throws: WorkerProtocolError.self) { try await gate.resume(UUID()) }
      #expect(await gate.pausedToken == token)
      try await gate.resume(token)
      #expect(try await gate.run { 7 } == 7)
      try await gate.resume(token)
      await gate.close()
    }
  }

  @Test func cancelledWaiterDoesNotReleaseFenceAndCloseTerminatesWaiters() async throws {
    let gate = WorkerOwnerTransactions(), token = UUID()
    try await gate.pause(token, drainTimeout: .seconds(2), waitTimeout: .seconds(5))
    let cancelled = Task { try await gate.run { Issue.record("Cancelled waiter ran") } }
    try await until { await gate.waitingCount == 1 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await gate.requirePaused(token)
    let blocked = Task { try await gate.run { Issue.record("Closed gate admitted an effect") } }
    try await until { await gate.waitingCount == 1 }
    await gate.close()
    await #expect(throws: WorkerProtocolError.self) { try await blocked.value }
    await #expect(throws: WorkerProtocolError.self) { try await gate.resume(token) }
  }

  @Test func successfulDrainHoldsNewCallsUntilResume() async throws {
    let gate = WorkerOwnerTransactions(), token = UUID()
    let entered = AsyncStream<Void>.makeStream(), held = AsyncStream<Void>.makeStream()
    defer { entered.continuation.finish(); held.continuation.finish() }
    let active = Task {
      try await gate.run {
        entered.continuation.yield(())
        for await _ in held.stream {}
      }
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    let pause = Task { try await gate.pause(token, drainTimeout: .seconds(2), waitTimeout: .seconds(5)) }
    try await until { await gate.pausedToken == token }
    let blocked = Task { try await gate.run { 9 } }
    try await until { await gate.waitingCount == 2 }
    held.continuation.finish()
    try await active.value
    try await pause.value
    try await gate.requirePaused(token)
    try await gate.resume(token)
    #expect(try await blocked.value == 9)
    await gate.close()
  }

  private var timeout: WorkerProtocolError { .init(.handoffTimedOut, message: "Worker owner transaction fence timed out") }

  private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0 ..< 10000 {
      if await condition() { return }
      await Task.yield()
    }
    _ = try #require(await condition(), "Fence did not reach the expected state")
  }
}
