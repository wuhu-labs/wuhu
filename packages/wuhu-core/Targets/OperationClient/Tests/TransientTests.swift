#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
@testable import OperationClient
import OperationProtocol
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct TransientTests {
  /// A caller cancelled while the machine's answer to its start is on the way leaves the operation abandoned: the machine gets
  /// the stop once the start is answered, and the driver ends.
  @Test func aTransientStartWhoseCallerLeftIsStopped() async throws {
    let wire = try Wire()
    let arrived = Signal(), answered = Signal()
    let fetch = FetchClient { request in
      let response = try await wire.fetch(request)
      if request.method == .post { arrived.fire(); await answered.wait() }
      return response
    }
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: MemoryOperationStore())
    let caller = Task { try await operations.transient(.init(scope: "test", key: "left"), machine: "disk", start: emit(wait: true)) }
    await arrived.wait()
    caller.cancel()
    await #expect(throws: (any Error).self) { _ = try await caller.value }
    answered.fire()
    #expect(try await eventually { wire.headers.withLock { $0.contains { $0.path.hasSuffix("/stop") } } })
    #expect(try await eventually { await operations.running == 0 })
    await operations.shutdown(); await wire.close()
  }

  /// A shutdown while a transient start waits for its tunnel lanes refuses that start and gives the lanes back.
  @Test func aShutdownRefusesATransientStartStillBeingAdmitted() async throws {
    let wire = try Wire()
    let asked = Signal(), cancelled = Signal()
    let first = Mutex(true)
    // Room for one emit.v1 (two lanes) beside the describe streams.
    let tunnel = TunnelLanes { _ in
      if first.withLock({ value in defer { value = false }; return value }) {
        asked.fire()
        await withTaskCancellationHandler { await cancelled.wait() } onCancel: { cancelled.fire() }
      }
      return TunnelLanes.describeStreams + 2
    }
    let closing = try wire.operations(tunnel: tunnel)
    let start = Task { try await closing.transient(.init(scope: "test", key: "late"), machine: "disk", start: emit()) }
    await asked.wait()
    await closing.shutdown()
    let refusal = await #expect(throws: OperationError.self) { _ = try await start.value }
    #expect(refusal?.code == .requestCancelled)
    #expect(wire.posts.withLock { $0 } == 0)
    let next = try wire.operations(tunnel: tunnel)
    let operation = try await next.transient(.init(scope: "test", key: "next"), machine: "disk", start: emit())
    #expect(try await operation.verdict().tag == .completed)
    await next.shutdown(); await wire.close()
  }
}
