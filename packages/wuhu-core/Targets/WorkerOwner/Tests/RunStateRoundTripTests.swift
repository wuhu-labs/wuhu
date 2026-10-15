#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct ExecutionOwner.InProcessExecutionOwnerClient
import JSONValue
import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol
import WuhuAI

// A worker tells the parent when a forced compaction runs, so the sessions
// row reads inference during one that starts from a settled turn.
@Suite(.timeLimit(.minutes(1))) struct RunStateRoundTripTests {
  let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")

  private func runState(_ space: Space, _ id: SessionID) async throws -> String {
    let rows = try await space.query("SELECT run_state FROM sessions WHERE id = ?", arguments: [.string(id.rawValue)], as: .shared(.anonymous))
    guard case let .text(value)? = rows.rows.first?.first else { return "" }
    return value
  }

  private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
    for _ in 0 ..< 500 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting for \(what)")
  }

  // During an upgrade a running old server can spawn its worker from the
  // binary already replaced on disk; that parent has no mark-compacting.
  @Test func aWorkerOnAnOlderParentSkipsRunStateWithoutFailing() async throws {
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "older", kind: .agent, createdBy: "owner", model: model)
    let current = ExecutionWorkerBootstrap.hello(release: "current")
    let older = WorkerHello(capabilities: current.capabilities.subtracting([ExecutionWorkerBootstrap.runStateCapability]), required: current.required, release: "older")
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), hello: older) { _, remote in
      try await remote.markCompacting(id, active: true)
      #expect(try await runState(space, id) == "no_run")
    }
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      try await remote.markCompacting(id, active: true)
      #expect(try await runState(space, id) == "inference")
      try await remote.markCompacting(id, active: false)
      #expect(try await runState(space, id) == "no_run")
    }
  }

  // The hard limit forces a compaction right after a settled reply. Shutting
  // the loop down cancels it with the hold still normal, and nothing else
  // would rewrite the row.
  @Test func cancellingAHeldHardLimitCompactionSettlesTheRow() async throws {
    let space = try Space.inMemory()
    let id = try await space.sessions.createSession(group: .shared, title: "hard limit", kind: .agent, createdBy: "owner", model: model)
    let compacting = Mutex(0)
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space)) { _, remote in
      let config = LoopConfig(
        executeTool: { _ in throw CancellationError() },
        inference: { request in
          guard request.mode == .forcedCompact else {
            return InferenceReply(
              message: .init(content: [.text("hi")]),
              metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 900_000)),
            )
          }
          compacting.withLock { $0 += 1 }
          try await Task.sleep(for: .seconds(3600))
          throw CancellationError()
        },
        compact: { _, _ in throw CancellationError() },
        budget: { _ in .init(maxInput: 1_001_000, maxOutput: 1000) },
        // No pressure notice: the transcript stays settled throughout.
        thresholds: .init(soft: 0.99, hard: 0.85),
      )
      let service = await SessionService(sessions: space.sessions, owner: remote, loopConfig: config)
      let start = Task { try await service.start() }
      let input = QueueInput.notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "hello")))
      _ = try await service.enqueue(item: input, to: id)
      try await eventually("forced compaction engaged") { compacting.withLock { $0 } == 1 }
      #expect(try await space.sessions.record(id).work == .noWork)
      #expect(try await runState(space, id) == "inference")

      // Cancelling start shuts the service down, as a server stop does.
      start.cancel()
      try? await start.value
      try await eventually("run state settled") { try await runState(space, id) == "no_run" }
      #expect(try await space.sessions.record(id).hold == .normal)
    }
  }
}
