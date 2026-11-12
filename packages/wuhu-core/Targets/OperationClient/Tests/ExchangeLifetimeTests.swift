#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import OperationClient
import OperationProtocol
import OperationRuntime
import func TaskLifetime.uncancellable
import Testing
import Tracing

private final class AdapterGate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream() }
  func wait() async { for await _ in stream {} }
  func release() { continuation.finish() }
}

@Test(.timeLimit(.minutes(1))) func deadlineDoesNotWaitForAnExpiredPoisonedAdapter() async throws {
  let gate = AdapterGate()
  let (started, start) = AsyncStream<Void>.makeStream()
  let (ended, end) = AsyncStream<Void>.makeStream()
  let clock = OperationClock(now: { .zero }, sleep: { _ in
    for await _ in started { break }
  })
  let link = MachineLink(
    origin: URL(string: "https://memory.invalid")!,
    fetch: FetchClient { _ in
      await uncancellable("Simulate a transport that ignores deadline cancellation") {
        start.yield(()); start.finish()
        await gate.wait()
      }
      end.yield(()); end.finish()
      throw CancellationError()
    },
    clock: clock, ids: { UUID() }, tracer: NoOpTracer(),
  )
  do { _ = try await link.send(MachineDescription.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: OperationLimits.responseBytes).result.get(); Issue.record("Expected a deadline") }
  catch { #expect(error.code == .requestDeadline) }
  #expect(link.taskScope.liveTasks.contains("machine-exchange"))
  link.taskScope.cancel()
  #expect(link.taskScope.liveTasks.contains("machine-exchange"))
  gate.release()
  for await _ in ended { break }
  await link.taskScope.close()
  #expect(link.taskScope.liveTasks.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func cancelledClockSleepDisablesOnlyTheExchangeTimer() async throws {
  let (slept, sleep) = AsyncStream<Void>.makeStream()
  let agent = try OperationAgent(machine: "disk", kinds: [], authorize: { _, _ in })
  let clock = OperationClock(now: { .zero }, sleep: { _ in
    sleep.yield(()); sleep.finish()
    throw CancellationError()
  })
  let link = MachineLink(
    origin: URL(string: "https://memory.invalid")!,
    fetch: FetchClient { request in
      for await _ in slept { break }
      return try await agent.handler(request)
    },
    clock: clock, ids: { UUID() }, tracer: NoOpTracer(),
  )
  let description = try await link.send(MachineDescription.self, "disk", .describe, correlation: nil, deadline: .seconds(5), limit: OperationLimits.responseBytes).result.get()
  #expect(description.version == 2)
  await link.taskScope.close()
  await agent.shutdown()
}
