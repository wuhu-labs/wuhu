#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct AssignmentHandoffTests {
  @Test func inFlightInferenceCommitsBeforeReleaseAndItsToolsRunOnlyOnTheNewOwner() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "handoff", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), yielded = Box(false), oldTools = Box(0)
      let release = Latch()
      let owner = InProcessSessionExecutionOwnerClient(sessions: sessions)
      let old = await SessionExecution(owner: owner, loopConfig: makeConfig(executeTool: { _ in
        oldTools.withLock { $0 += 1 }
        throw UnexpectedCall("old worker tool")
      }, inference: { _ in
        entered.withLock { $0 = true }
        await release.wait()
        try Task.checkCancellation()
        return Fix.reply("working", calls: [.init(id: "call", name: "exec", arguments: .object([:]))])
      }))
      _ = try await old.enqueue(Fix.message("work"), to: id)
      try await until("inference entered") { entered.value }
      let handoff = Task { await old.yieldAssignment(id); yielded.withLock { $0 = true } }
      defer { release.release(); handoff.cancel() }
      try await holds("handoff waits for inference") { !yielded.value }
      release.release()
      await handoff.value
      #expect(oldTools.value == 0)
      #expect(try await sessions.hydrate(id).transcript.kernel.pendingToolCallIDs.count == 1)
      await #expect(throws: SessionExecutionRetired.self) { try await old.wake(id) }
      let tools = Box(0)
      let next = await SessionExecution(owner: owner, loopConfig: makeConfig(executeTool: { _ in
        tools.withLock { $0 += 1 }
        return .exec(.init(output: "done", exitCode: 0))
      }, inference: { _ in Fix.reply("done") }))
      try await next.wake(id)
      try await until("new owner settles") { try await sessions.settledWork(id) }
      #expect(tools.value == 1)
      await old.shutdown()
      await next.shutdown()
    }
  }

  @Test func inFlightToolFinishesBeforeReleaseWithoutStartingTheNextInference() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "tool", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), inferences = Box(0), yielded = Box(false)
      let release = Latch()
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig(executeTool: { _ in
        entered.withLock { $0 = true }
        await release.wait()
        try Task.checkCancellation()
        return .exec(.init(output: "once", exitCode: 0))
      }, inference: { _ in
        inferences.withLock { $0 += 1 }
        return Fix.reply("working", calls: [.init(id: "call", name: "exec", arguments: .object([:]))])
      }))
      _ = try await old.enqueue(Fix.message("work"), to: id)
      try await until("tool entered") { entered.value }
      let handoff = Task { await old.yieldAssignment(id); yielded.withLock { $0 = true } }
      defer { release.release(); handoff.cancel() }
      try await holds("handoff waits for tool") { !yielded.value }
      release.release()
      await handoff.value
      #expect(inferences.value == 1)
      #expect(try await sessions.hydrate(id).transcript.kernel.pendingToolCallIDs.isEmpty)
      await old.shutdown()
    }
  }

  @Test func inFlightCompactionCommitsBeforeReleaseWithoutStartingAnotherInference() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "compact", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false), yielded = Box(false), inferences = Box(0)
      let release = Latch()
      var config = makeConfig(inference: { _ in
        inferences.withLock { $0 += 1 }
        return Fix.reply("compacting", calls: [.init(id: "compact", name: "compact", arguments: .object(["summary": .string("remembered")]))])
      })
      config.prepareCompaction = { _, _, _ in
        entered.withLock { $0 = true }
        await release.wait()
        return nil
      }
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: config)
      _ = try await old.enqueue(Fix.message("compact"), to: id)
      try await until("compaction entered") { entered.value }
      let handoff = Task { await old.yieldAssignment(id); yielded.withLock { $0 = true } }
      defer { release.release(); handoff.cancel() }
      try await holds("handoff waits for compaction") { !yielded.value }
      release.release()
      await handoff.value
      #expect(inferences.value == 1)
      #expect(try await sessions.hydrate(id).generation == 1)
      #expect(try await sessions.hydrate(id).transcript.kernel.pendingToolCallIDs.isEmpty)
      await old.shutdown()
    }
  }

  @Test func archiveReservationPinsTheAssignmentAndCancelledWaitDoesNotReleaseIt() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "reserved", kind: .agent, createdBy: "morgan", model: .test)
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig())
      let reservation = UUID()
      #expect(try await old.prepareArchive(id, reservation: reservation))
      let handoff = Task { await old.yieldAssignment(id) }
      try await until("yield requested") { await old.registry.sessions[id]?.yielding == true }
      handoff.cancel()
      try await holds("reservation retains old actor") { await old.registry.sessions[id] != nil }
      try await old.releaseArchive(id, reservation: reservation)
      await handoff.value
      #expect(await old.registry.sessions[id] == nil)
      await #expect(throws: SessionExecutionRetired.self) { try await old.wake(id) }
      await old.shutdown()
    }
  }

  @Test func releaseWaitsForEndActivityAcknowledgement() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "activity", kind: .agent, createdBy: "morgan", model: .test)
      let ending = Box(false), yielded = Box(false)
      let release = Latch()
      var config = makeConfig(inference: { _ in Fix.reply("done") })
      config.executionActivity = { _, _, active in
        guard !active else { return }
        ending.withLock { $0 = true }
        await release.wait()
      }
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: config)
      try await old.wake(id)
      try await until("end activity entered") { ending.value }
      let handoff = Task { await old.yieldAssignment(id); yielded.withLock { $0 = true } }
      defer { release.release(); handoff.cancel() }
      try await holds("release waits for owner acknowledgement") { !yielded.value }
      release.release()
      await handoff.value
      #expect(await old.registry.sessions[id] == nil)
      await old.shutdown()
    }
  }

  @Test func explicitInterruptStillCompletesWhileTheAssignmentIsYielding() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "interrupt", kind: .agent, createdBy: "morgan", model: .test)
      let entered = Box(false)
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig(inference: { _ in
        entered.withLock { $0 = true }
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(1_000_000))
        throw UnexpectedCall("inference elapsed")
      }))
      _ = try await old.enqueue(Fix.message("work"), to: id)
      try await until("inference entered") { entered.value }
      let handoff = Task { await old.yieldAssignment(id) }
      try await until("yield requested") { await old.registry.sessions[id]?.yielding == true }
      try await old.interrupt(id)
      await handoff.value
      #expect(try await sessions.record(id).hold == .interrupted)
      await old.shutdown()
    }
  }

  @Test func yieldingCancelsOnlyRetryPauseWithoutWaitingForItsDeadline() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "backoff", kind: .agent, createdBy: "morgan", model: .test)
      let attempts = Box(0)
      let old = await SessionExecution(owner: InProcessSessionExecutionOwnerClient(sessions: sessions), loopConfig: makeConfig(inference: { _ in
        attempts.withLock { $0 += 1 }
        throw InferenceError.transient(status: 503, body: nil)
      }))
      _ = try await old.enqueue(Fix.message("work"), to: id)
      try await until("retry pause installed") { await old.registry.sessions[id]?.retryPause != nil }
      await old.yieldAssignment(id)
      #expect(attempts.value == 1)
      #expect(try await sessions.record(id).work != .errored)
      await old.shutdown()
    }
  }
}
