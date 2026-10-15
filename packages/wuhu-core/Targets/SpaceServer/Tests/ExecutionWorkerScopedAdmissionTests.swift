#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Credentials
import Dependencies
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import LoopCore
import OperationClient
import OperationProtocol
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerScopedAdmissionTests {
  @Test func deferredExecutionIsAnOperatorConflictRatherThanAnInternalServerError() async throws {
    let response = sessionErrorResponse(SessionExecutionDeferred(session: .init("blocked-session")))
    #expect(response.status == .conflict)
    let body = try await response.json(JSONValue.self)
    #expect(body.object?["code"] == .string("sessionExecutionDeferred"))
  }

  @Test(arguments: [false, true]) func deferredSessionsKeepQueuedWorkAndRejectMutatingExecutionVerbs(worker: Bool) async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "blocked", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let fence = ExecutionWorkerBootFence.Result(blockedSessions: [id], credentials: .init())
      let runtime = await SessionRuntime.assemble(space: space, hub: .init(space: space), attemptLog: nil, metrics: .noop, credentials: .unavailable, secrets: nil, usage: .init(), executionPlacement: worker ? .worker(executable: URL(fileURLWithPath: "/not-a-worker")) : .inProcess, startupFence: fence)
      _ = try await runtime.service.enqueue(item: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "retained"))), to: id)
      try await runtime.service.wake(id)
      await #expect(throws: SessionExecutionDeferred.self) { try await runtime.service.resume(id) }
      await #expect(throws: SessionExecutionDeferred.self) { try await runtime.service.interrupt(id) }
      await #expect(throws: SessionExecutionDeferred.self) { try await runtime.service.restart(id, executor: nil, note: nil) }
      await #expect(throws: SessionExecutionDeferred.self) { try await runtime.service.archive(id, force: true) }
      #expect(try await space.sessions.undrainedInputs(id).count == 1)
      #expect(try await space.sessions.record(id).work != .errored)
      #expect(try await space.sessions.record(id).lifecycle == .live)
      await runtime.service.shutdown()
    }
  }

  @Test func ownershipMarkerAndAssignmentAreDurableBeforeStarterRuns() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "assignment", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { incarnation, _, _ in
        #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [id])
        throw CancellationError()
      })
      _ = await Task { try await worker.wake(id) }.result
      await worker.shutdown()
    }
  }

  @Test func blockedHandlerNeverStartsWorker() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = SessionID("blocked-session")
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, _, _ in
        Issue.record("blocked handler started a worker")
        throw CancellationError()
      }, startupExcludedSessions: [id])
      await #expect(throws: ExecutionWorkerFencePending.self) { try await worker.executeHandler(.init(path: "/handler.js", session: id)) }
      #expect(await worker.processID == nil)
      await worker.shutdown()
    }
  }

  @Test func startupOrphanCleanupLeavesBlockedExecsButReapsOtherCallers() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let machine = try await space.addMachine(name: "fixture").id
      let blocked = SessionID("blocked-session")
      let retained = try await space.mintExec(machine: machine, caller: blocked.rawValue)
      let safe = try await space.mintExec(machine: machine)
      let hub = MachineHub(space: space, callerGrace: .zero, tokens: nil, startupExcludedSessions: [blocked])
      let running = Task { await hub.run() }
      do {
        try await until("safe orphan reaped") { try await space.execRecord(safe.id)?.terminal != nil }
        #expect(try await space.execRecord(retained.id)?.terminal == nil)
        #expect(try await space.execRecord(retained.id)?.killDelivered == false)
        running.cancel(); await running.value
      } catch { running.cancel(); await running.value; throw error }
    }
  }
}
