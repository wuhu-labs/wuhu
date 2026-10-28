#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dispatch
import Fetch
import OperationClient
import OperationProtocol
import OperationRuntime
import Synchronization
import Testing

private actor AdapterGate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var released = false
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func release() { released = true; waiter?.resume(); waiter = nil }
}

@Test(.timeLimit(.minutes(1))) func shutdownDoesNotWaitForAnExpiredPoisonedAdapter() async throws {
  let gate = AdapterGate()
  let (started, start) = AsyncStream<Void>.makeStream()
  let (ended, end) = AsyncStream<Void>.makeStream()
  let clock = OperationClock(now: { .zero }, sleep: { _ in
    for await _ in started { break }
  })
  let operations = try MachineOperations(
    origin: URL(string: "https://memory.invalid")!,
    fetch: FetchClient { _ in
      start.yield(()); start.finish()
      await gate.wait()
      end.yield(()); end.finish()
      throw CancellationError()
    },
    store: MemoryOperationStore(), clock: clock,
  )
  do { _ = try await operations.describe("disk"); Issue.record("Expected a deadline") }
  catch let error as OperationError { #expect(error.code == .requestDeadline) }
  await operations.shutdown()
  await gate.release()
  for await _ in ended { break }
}

@Test(.timeLimit(.minutes(1))) func cancelledClockSleepDisablesOnlyTheExchangeTimer() async throws {
  let (slept, sleep) = AsyncStream<Void>.makeStream()
  let agent = try OperationAgent(machine: "disk", kinds: [], authorize: { _, _ in })
  let clock = OperationClock(now: { .zero }, sleep: { _ in
    sleep.yield(()); sleep.finish()
    throw CancellationError()
  })
  let operations = try MachineOperations(
    origin: URL(string: "https://memory.invalid")!,
    fetch: FetchClient { request in
      for await _ in slept { break }
      return try await agent.handler(request)
    },
    store: MemoryOperationStore(), clock: clock,
  )
  let description = try await operations.describe("disk")
  #expect(description.version == 2)
  await operations.shutdown()
  await agent.shutdown()
}

@Test func resumeAfterShutdownRefusesAdmission() async throws {
  let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: FetchClient { _ in throw CancellationError() }, store: MemoryOperationStore())
  await operations.shutdown()
  do { _ = try await operations.resume(); Issue.record("Expected shutdown refusal") }
  catch let error as OperationError { #expect(error.code == .requestCancelled) }
}

@Test(.timeLimit(.minutes(1))) func exchangeDeadlineStartsBeforeDispatchTracing() async throws {
  let entered = AsyncStream<Void>.makeStream()
  let finished = AsyncStream<Void>.makeStream()
  let gate = DispatchSemaphore(value: 0)
  let clock = OperationClock(now: { .zero }, sleep: { _ in
    for await _ in entered.stream { break }
  })
  let operations = try MachineOperations(
    origin: URL(string: "https://memory.invalid")!, fetch: FetchClient { _ in throw CancellationError() },
    store: MemoryOperationStore(), clock: clock, trace: { trace in
      if trace.event == .dispatch {
        entered.continuation.yield(()); entered.continuation.finish()
        gate.wait()
        finished.continuation.yield(()); finished.continuation.finish()
      }
    },
  )
  defer { gate.signal() }
  do { _ = try await operations.describe("disk"); Issue.record("Expected a deadline") }
  catch let error as OperationError { #expect(error.code == .requestDeadline) }
  await operations.shutdown()
  gate.signal()
  for await _ in finished.stream { break }
}
