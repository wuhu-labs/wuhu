#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import GRDB
import JSONValue
import SessionDomain
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

private struct GatedHandler: HandlerExecutionClient {
  let execute: @Sendable (ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await execute(invocation) }
}

private func stallAlerts(_ space: Space, to parent: SessionID, for request: RequestID) async throws -> Int {
  try await space.writer.read { db in
    try Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM session_queue WHERE session_id = ? AND payload LIKE '%requestStall%' AND payload LIKE ?",
      arguments: [parent.rawValue, "%\(request.rawValue)%"],
    ) ?? 0
  }
}

// A request's stall clock against the real runtimes: what holds it and what
// must not.
@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct RequestStallRuntimeTests {
  @Test func aHandlerFiringOnAWorkerDoesNotHoldTheClock() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let model = SessionExecutor.kernel(.init(provider: "offline", model: "small", effort: "none"))
      let parent = try await space.sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "owner", executor: model)
      let task = try await space.sessions.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: model)
      let request = RequestID("stall-worker")
      _ = try await space.sessions.openRequest(on: task, from: parent, messageID: MessageID(request.rawValue), text: "go", deadline: nil, stallSeconds: 600)
      let due = try #require(try await space.sessions.armedSubscriptions(parent).first { $0.slot.id == .stall(request) }?.nextFireAt)

      let entered = Gate()
      let release = Gate()
      let started = Mutex<UUID?>(nil)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { incarnation, _, _ in
        started.withLock { $0 = incarnation }
        // As a worker's script lifecycle does, the firing holds an owner row
        // of its own beside the parent's bridge row while it runs.
        let handler = WorkerHandlerEndpoint(handler: GatedHandler { invocation in
          let script = "handler-" + invocation.id.uuidString
          try await space.sessions.registerWorkerScript(script, session: task, incarnation: incarnation)
          entered.open()
          await release.wait()
          try await space.sessions.releaseWorkerScript(script, session: task, incarnation: incarnation)
          return .init(stateJSON: "null", wakes: [])
        })
        let hello = ExecutionWorkerBootstrap.hello(release: "fixture")
        let bytes = OwnerByteEndpoint(invoke: handler.invoke)
        let endpoint = try bytes.endpoint(token: "fixture", hello: hello)
        let fetch = FetchClient { try await endpoint.handler($0) }
        let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
        _ = try await client.negotiate(hello)
        let lifetime = Task { let (stream, continuation) = AsyncStream<Void>.makeStream(); for await _ in stream {}; continuation.finish(); await bytes.shutdown(); await handler.shutdown() }
        return WorkerConnection(processID: 123, client: client, lifetime: lifetime)
      })
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          let result = try await worker.executeHandler(.init(path: "/handler.js", session: task))
          await result.acknowledge()
        }
        await entered.wait()
        let incarnation = try #require(started.withLock { $0 })
        let rows = try await space.writer.read { db in
          try String.fetchAll(db, sql: "SELECT script_id FROM worker_script_owners WHERE session_id = ? AND incarnation = ?", arguments: [task.rawValue, incarnation.uuidString])
        }
        #expect(rows.count == 2)
        try await space.sessions.checkRequestStall(parent, subscriptionID: .stall(request), now: due.addingTimeInterval(1))
        #expect(try await stallAlerts(space, to: parent, for: request) == 1)
        release.open()
        try await group.waitForAll()
      }
      await worker.shutdown()
    }
  }

  @Test func archiveStopsAnInProcessScriptSoItCannotHoldALaterRequest() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(assembledModels: testModelsJSON)
      let space = harness.space
      let scripts = try #require(harness.runtime.scripts)
      let model = SessionExecutor.kernel(.init(provider: "offline", model: "small", effort: "none"))
      let parent = try await harness.store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "owner", executor: model)
      let task = try await harness.store.createSession(group: .shared, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue, executor: model)
      func taskScripts() -> Int { scripts.inventory.values.filter { $0 == task }.count }

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        let started = try await callResult(harness, task.rawValue, tool: "run_script", .object([
          "source": .string("result('watching'); await sleep(3_600_000)"),
        ]))
        #expect(resultText(started)?.contains("watching") == true)
        #expect(taskScripts() == 1)

        // The production firing sees the script as a wait.
        let first = RequestID("stall-before-archive")
        _ = try await harness.store.openRequest(on: task, from: parent, messageID: MessageID(first.rawValue), text: "watch", deadline: nil, stallSeconds: 1)
        try await ContinuousClock().sleep(for: .seconds(3))
        #expect(try await stallAlerts(space, to: parent, for: first) == 0)

        try await harness.runtime.service.archive(task, force: true)
        try await until("archive stops the task's script") { taskScripts() == 0 }
        try await harness.runtime.service.unarchive(task)

        let second = RequestID("stall-after-unarchive")
        _ = try await harness.store.openRequest(on: task, from: parent, messageID: MessageID(second.rawValue), text: "again", deadline: nil, stallSeconds: 1)
        try await until("the new request's stall alert") { try await stallAlerts(space, to: parent, for: second) == 1 }
      }
    }
  }
}
