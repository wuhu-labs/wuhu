#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Credentials
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import LoopCore
import ServeNIO
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(2))) struct ExecutionWorkerHandoffTests {
  private func binary() throws -> String {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
  }

  private func session(_ space: Space) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: "handoff", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
  }

  private func input(_ text: String) -> QueueInput {
    .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("fixture"), content: .init(text: text)))
  }

  private func runtime() -> WorkerRuntimeOwner {
    .init(attempts: .init(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleReminder: { _, _ in }, scheduleWarming: { _, _ in })
  }

  private func models(_ space: Space, port: Int) async throws {
    let json = """
    {"offline":{"dialect":"anthropic","baseURL":"http://127.0.0.1:\(port)","opaqueReplay":"none","models":{"small":{"maxInput":100000,"maxOutput":1000,"efforts":["none"],"defaultEffort":"none"}}}}
    """
    _ = try await space.fs(.shared).write("/models.json", Data(json.utf8), ifMatch: nil)
  }

  private func reply(tool: String? = nil, arguments: JSONValue = .object([:])) -> Response {
    let block: JSONValue = if let tool {
      ["index": 0, "content_block": ["type": "tool_use", "id": .string("call-\(UUID())"), "name": .string(tool), "input": [:]]]
    } else { ["index": 0, "content_block": ["type": "text", "text": ""]] }
    let events: [(String, JSONValue)] = [
      ("message_start", ["message": ["usage": ["input_tokens": 10]]]),
      ("content_block_start", block),
      ("content_block_delta", ["index": 0, "delta": tool == nil ? ["type": "text_delta", "text": "done"] : ["type": "input_json_delta", "partial_json": .string(arguments.jsonString())]]),
      ("content_block_stop", ["index": 0]),
      ("message_delta", ["delta": ["stop_reason": tool == nil ? "end_turn" : "tool_use"], "usage": ["output_tokens": 1]]),
      ("message_stop", [:]),
    ]
    let sse = events.map { "event: \($0.0)\ndata: \($0.1.jsonString())\n\n" }.joined()
    return .init(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
  }

  @Test func ownerTransportReconnectPreservesInferenceAndInventoryInSameChild() async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      defer { release.continuation.finish(); gate.cancel() }
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        requests.withLock { $0 += 1 }
        await gate.value
        return reply()
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: .init { _ in .apiKey("fixture") })
      let exits = Mutex(0)
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: runtime(), activity: { _ in }, exited: { exits.withLock { $0 += 1 } })
      let worker = RemoteSessionExecution(client: connection.client)
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        let id = try await session(space)
        _ = try await service.enqueue(item: input("continuity"), to: id)
        try await until("inference admitted", timeout: .seconds(40)) { requests.withLock { $0 } == 1 }
        let before = try await worker.inventory()
        #expect(before.assignments.contains { $0.session == id && !$0.passes.isEmpty })
        #expect(before.inferences[id]?.count == 1)
        await connection.ownerTransport?.detach()
        let during = try await worker.inventory()
        #expect(during.inferences[id] == before.inferences[id])
        #expect(kill(connection.processID, 0) == 0)
        #expect(exits.withLock { $0 } == 0)
        release.continuation.yield(())
        try await until("original inference commits after reconnect", timeout: .seconds(40)) { try await space.sessions.transcript(id).items.contains { if case .assistant = $0 { true } else { false } } }
        #expect(requests.withLock { $0 } == 1)
        #expect(try await space.sessions.record(id).work != .errored)
        result = .success(())
      } catch { result = .failure(error) }
      release.continuation.finish()
      await connection.stop(); await provider.shutdown()
      try result.get()
    }
  }

  @Test func ownerTransportReconnectKeepsAdmittedHandlerObserveAndReturnedReceipt() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let source = """
      import {observe,writeText} from 'wuhu:space';
      export default async ({state,wake}) => {
        await writeText('/continuity-started.txt','yes',{ifMatch:null});
        for await (const rows of observe("SELECT title FROM sessions WHERE id = '\(id.rawValue)'")) {
          if (rows[0]?.title === 'release') { wake('once'); return {previous:state,done:true}; }
        }
      }
      """
      _ = try await space.fs(.shared).write("/continuity.js", Data(source.utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime(), activity: { _ in }, exited: {})
      let firing = UUID()
      let handler = Task { try await RemoteHandlerExecution(client: connection.client).executeHandler(.init(id: firing, path: "/continuity.js", session: id, stateJSON: "{\"before\":1}")) }
      let outcome: Result<Void, any Error>
      do {
        try await until("handler admitted", timeout: .seconds(40)) { (try? await space.fs(.shared).read("/continuity-started.txt").1) != nil }
        let before = try await RemoteSessionExecution(client: connection.client).inventory()
        #expect(!before.scripts.isEmpty)
        await connection.ownerTransport?.detach()
        _ = try await space.sessions.setTitle(id, to: "release")
        let result = try await handler.value
        #expect(result.wakes == ["once"])
        #expect(JSONValue.parse(result.stateJSON) == ["previous": ["before": 1], "done": true])
        #expect(kill(connection.processID, 0) == 0)
        let receipts = try JSONDecoder().decode([WorkerCallInventory].self, from: Data(try await connection.client.call(.init(operation: "owner.receipts")).jsonString().utf8))
        #expect(receipts.contains { $0.id == firing && $0.terminal })
        await result.acknowledge()
        outcome = .success(())
      } catch { outcome = .failure(error) }
      handler.cancel(); _ = await handler.result
      await connection.stop()
      try outcome.get()
    }
  }

  @Test func newAssignmentsUseNewChildWhileOldInferenceCommitsAndThenYields() async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      defer { release.continuation.finish(); gate.cancel() }
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        let count = requests.withLock { $0 += 1; return $0 }
        if count == 1 { await gate.value }
        return reply()
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: .init { _ in .apiKey("fixture") })
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: runtime())
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        let first = try await session(space), second = try await session(space)
        _ = try await service.enqueue(item: input("first"), to: first)
        try await until("first provider request", timeout: .seconds(40)) { requests.withLock { $0 } == 1 }
        let oldPID = try #require(await worker.processID)
        try await worker.replaceGeneration()
        _ = try await service.enqueue(item: input("second"), to: second)
        try await until("new assignment completes on replacement", timeout: .seconds(40)) { try await space.sessions.transcript(second).items.contains { if case .assistant = $0 { true } else { false } } }
        #expect(await worker.generationCount == 2)
        #expect(await worker.processID != oldPID)
        #expect(kill(oldPID, 0) == 0)
        #expect(try await space.sessions.transcript(first).items.count == 1)
        release.continuation.yield(())
        try await until("old inference commits", timeout: .seconds(40)) { try await space.sessions.transcript(first).items.contains { if case .assistant = $0 { true } else { false } } }
        try await until("old generation retires", timeout: .seconds(40)) { await worker.generationCount == 1 }
        #expect(requests.withLock { $0 } == 2)
        #expect(try await space.sessions.record(first).work != .errored)
        result = .success(())
      } catch { result = .failure(error) }
      release.continuation.finish()
      await worker.shutdown(); await provider.shutdown()
      try result.get()
    }
  }

  @Test func crashedDrainingChildReconcilesItsLeaseBeforeMovingTheAssignment() async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      defer { release.continuation.finish(); gate.cancel() }
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        let count = requests.withLock { $0 += 1; return $0 }
        if count == 1 { await gate.value }
        return reply()
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: .init { _ in .apiKey("fixture") })
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: runtime())
      let result: Result<Void, any Error>
      do {
        let id = try await session(space)
        _ = try await worker.enqueue(input("first"), to: id)
        try await until("first inference admitted", timeout: .seconds(40)) { requests.withLock { $0 } == 1 }
        let oldPID = try #require(await worker.processID)
        try await worker.replaceGeneration()
        #expect(kill(oldPID, SIGKILL) == 0)
        release.continuation.yield(())
        try await until("replacement settles recovered assignment", timeout: .seconds(40)) { try await space.sessions.record(id).work == .noWork }
        try await until("dead generation releases after reconciliation", timeout: .seconds(40)) { await worker.generationCount == 1 }
        #expect(await worker.processID != oldPID)
        #expect(try await space.sessions.workerCrashFenced(id) == false)
        #expect(requests.withLock { $0 } == 2)
        result = .success(())
      } catch { result = .failure(error) }
      release.continuation.finish()
      await worker.shutdown(); await provider.shutdown()
      try result.get()
    }
  }

  @Test func detachedObserveScriptStaysOnOldChildAndStopFromNewChildRoutesToIt() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let scriptToStop = Mutex<String?>(nil)
      let requests = Mutex(0)
      let source = """
      import {observe,writeText} from 'wuhu:space';
      let ready = false;
      for await (const rows of observe("SELECT title FROM sessions WHERE id = '\(id.rawValue)'")) {
        if (!ready) { ready = true; result('watching'); }
        if (rows[0]?.title === 'changed') await writeText('/observed-after-handoff.txt','alive',{ifMatch:null});
      }
      """
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        let count = requests.withLock { $0 += 1; return $0 }
        if count == 1 { return reply(tool: "run_script", arguments: ["source": .string(source), "timeout_seconds": 10]) }
        if count == 3 { return reply(tool: "stop_script", arguments: ["id": .string(try #require(scriptToStop.withLock { $0 }))]) }
        return reply()
      })
      try await models(space, port: #require(provider.localAddress?.port))
      let executionOwner = InProcessExecutionOwnerClient(space: space, credentials: .init { _ in .apiKey("fixture") })
      let owner = InProcessToolOwnerClient(space: space, executionOwner: executionOwner)
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime())
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        _ = try await service.enqueue(item: input("start script"), to: id)
        try await until("script detaches and session settles", timeout: .seconds(40)) {
          let record = try await space.sessions.record(id)
          return requests.withLock { $0 } == 2 && record.work == .noWork
        }
        let script = try #require(await worker.runningScripts(id).first)
        scriptToStop.withLock { $0 = script }
        let oldPID = try #require(await worker.processID)
        try await worker.replaceGeneration()
        try await until("actor reaches replacement", timeout: .seconds(40)) { await worker.processID != nil }
        #expect(await worker.generationCount == 2)
        #expect(kill(oldPID, 0) == 0)
        _ = try await space.sessions.setTitle(id, to: "changed")
        try await until("old script observes parent change", timeout: .seconds(40)) { (try? await space.fs(.shared).read("/observed-after-handoff.txt").1) == Data("alive".utf8) }
        _ = try await service.enqueue(item: input("stop script"), to: id)
        try await until("new child stops old script", timeout: .seconds(40)) { await worker.runningScripts(id).isEmpty }
        try await until("old child retires after script exit", timeout: .seconds(40)) { await worker.generationCount == 1 }
        try await until("stop result commits", timeout: .seconds(40)) {
          let transcript = try await space.sessions.transcript(id)
          return transcript.items.contains { item in
            guard case let .toolResult(result) = item, case let .script(output) = result.payload else { return false }
            return output.output.contains("script \(script) was killed") || output.output.contains("script \(script) stopped")
          }
        }
        result = .success(())
      } catch { result = .failure(error) }
      await worker.shutdown(); await provider.shutdown()
      try result.get()
    }
  }

  @Test func admittedHandlerFinishesOnOldGenerationWhileNewHandlersUseReplacement() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let source = """
      import {observe,writeText} from 'wuhu:space';
      export default async ({state,wake}) => {
        await writeText('/handler-started.txt','yes',{ifMatch:null});
        for await (const rows of observe("SELECT title FROM sessions WHERE id = '\(id.rawValue)'")) {
          if (rows[0]?.title === 'release') { wake('old finished'); return {previous:state,done:true}; }
        }
      }
      """
      _ = try await space.fs(.shared).write("/blocked.js", Data(source.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/healthy.js", Data("export default async () => ({replacement:true})".utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime())
      let handler = Task { try await worker.executeHandler(.init(path: "/blocked.js", session: id, stateJSON: "{\"before\":1}")) }
      let result: Result<Void, any Error>
      do {
        try await until("handler admitted", timeout: .seconds(40)) { (try? await space.fs(.shared).read("/handler-started.txt").1) != nil }
        let oldPID = try #require(await worker.processID)
        try await worker.replaceGeneration()
        let next = try await worker.executeHandler(.init(path: "/healthy.js", session: id))
        #expect(JSONValue.parse(next.stateJSON) == ["replacement": true])
        await next.acknowledge()
        #expect(await worker.processID != oldPID)
        #expect(await worker.generationCount == 2)
        #expect(kill(oldPID, 0) == 0)
        _ = try await space.sessions.setTitle(id, to: "release")
        let previous = try await handler.value
        #expect(previous.wakes == ["old finished"])
        #expect(JSONValue.parse(previous.stateJSON) == ["previous": ["before": 1], "done": true])
        #expect(await worker.generationCount == 2)
        await previous.acknowledge()
        try await until("old handler generation retires", timeout: .seconds(40)) { await worker.generationCount == 1 }
        result = .success(())
      } catch { result = .failure(error) }
      handler.cancel(); _ = await handler.result
      await worker.shutdown()
      try result.get()
    }
  }
}
