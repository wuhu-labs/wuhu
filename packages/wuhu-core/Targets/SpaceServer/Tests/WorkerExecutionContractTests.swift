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
import ComputerFiles
import Credentials
import Crypto
import Dependencies
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
import ServeNIO
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import SpaceTools
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(2))) struct WorkerExecutionContractTests {
  private func binary() throws -> String {
    let path = try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func session(_ space: Space) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: "worker contract", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
  }

  private func runtime(_ space: Space) -> WorkerRuntimeOwner {
    .init(attempts: .init(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
  }

  @Test func workerExecutableResolutionUsesAnAbsoluteExistingBinary() throws {
    guard case let .worker(executable) = try ExecutionPlacement.worker() else { Issue.record("expected worker"); return }
    #expect(executable.path.hasPrefix("/"))
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
  }

  @Test func unavailableOptInWorkerNeverCreatesLocalExecutionHosts() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let runtime = await SessionRuntime.assemble(space: space, hub: .init(space: space), executionPlacement: .worker(executable: URL(fileURLWithPath: "/no-such-wuhu-worker")))
      #expect(runtime.scripts == nil && runtime.sockets == nil)
      let id = try await session(space)
      _ = try await runtime.service.enqueue(item: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("fixture"), content: .init(text: "must not run locally"))), to: id)
      await runtime.service.shutdown()
      #expect(runtime.attempts.inFlight(session: id).isEmpty)
      #expect(try await space.sessions.transcript(id).items.isEmpty)
      #expect(try await space.sessions.hydrate(id).undrained.count == 1)
    }
  }

  @Test func realChildRunsQuickJSAndPublishesOrderedAttempts() async throws {
    try await withSessionDeps {
      let bodies = Mutex<[JSONValue]>([])
      let source = "import {writeText,readText} from 'wuhu:space'; await writeText('/from-child.txt','worker-effect',{ifMatch:null}); result((await readText('/from-child.txt')).content)"
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        let body = try await request.body?.json(JSONValue.self) ?? .null
        let round = bodies.withLock { $0.append(body); return $0.count }
        let block: JSONValue = round == 1 ? .object(["index": 0, "content_block": .object(["type": "tool_use", "id": "script-call", "name": "run_script", "input": .object([:])])]) : .object(["index": 0, "content_block": .object(["type": "text", "text": ""])])
        let events: [(String, JSONValue)] = [
          ("message_start", .object(["message": .object(["usage": .object(["input_tokens": 10])])])),
          ("content_block_start", block),
          ("content_block_delta", .object(["index": 0, "delta": round == 1 ? .object(["type": "input_json_delta", "partial_json": .string(JSONValue.object(["source": .string(source), "timeout_seconds": 10, "on_timeout": "kill"]).jsonString())]) : .object(["type": "text_delta", "text": "finished in child"])])),
          ("content_block_stop", .object(["index": 0])),
          ("message_delta", .object(["delta": .object(["stop_reason": .string(round == 1 ? "tool_use" : "end_turn")]), "usage": .object(["output_tokens": 1])])),
          ("message_stop", .object([:])),
        ]
        let sse = events.map { "event: \($0.0)\ndata: \($0.1.jsonString())\n\n" }.joined()
        return .init(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      })
      let space = try Space.inMemory()
      let port = try #require(provider.localAddress?.port)
      let modelJSON = "{\"offline\":{\"dialect\":\"anthropic\",\"baseURL\":\"http://127.0.0.1:\(port)\",\"opaqueReplay\":\"none\",\"models\":{\"small\":{\"maxInput\":100000,\"maxOutput\":1000,\"efforts\":[\"none\"],\"defaultEffort\":\"none\"}}}}"
      _ = try await space.fs(.shared).write("/models.json", Data(modelJSON.utf8), ifMatch: nil)
      let runtime = await SessionRuntime.assemble(space: space, hub: .init(space: space), attemptLog: nil, metrics: .noop, credentials: .init { _ in .apiKey("fixture") }, secrets: nil, usage: .init(), executionPlacement: .worker(executable: URL(fileURLWithPath: try binary())))
      #expect(runtime.scripts == nil && runtime.sockets == nil)
      let id = try await session(space)
      let observed = Mutex<[String]>([])
      let events = runtime.attempts.events(session: id)
      let observer = Task {
        var finished = 0
        for await event in events {
          switch event {
          case .started: observed.withLock { $0.append("start") }
          case .delta: observed.withLock { $0.append("delta") }
          case .finished:
            observed.withLock { $0.append("finish") }
            finished += 1
            if finished == 2 { return }
          }
        }
      }
      let result: Result<Void, any Error>
      do {
        _ = try await runtime.service.enqueue(item: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("fixture"), content: .init(text: "run script"))), to: id)
        try await until("child completes script loop", timeout: .seconds(40)) {
          try await space.sessions.transcript(id).items.contains { if case let .assistant(entry) = $0 { entry.content.contains(.text("finished in child")) } else { false } }
        }
        #expect(try await space.fs(.shared).read("/from-child.txt").1 == Data("worker-effect".utf8))
        #expect(bodies.withLock { $0.count } == 2)
        #expect(bodies.withLock { $0.last?.jsonString().contains("worker-effect") } == true)
        try await until("attempt terminal events reach parent", timeout: .seconds(5)) { observed.withLock { $0.filter { $0 == "finish" }.count } == 2 }
        #expect(observed.withLock { $0.first } == "start")
        #expect(runtime.attempts.inFlight(session: id).isEmpty)
        result = .success(())
      } catch { result = .failure(error) }
      observer.cancel(); await observer.value
      await runtime.service.shutdown(); await provider.shutdown()
      try result.get()
    }
  }

  @Test(arguments: ["alpha", "beta"])
  func handlersInRealChildrenRouteRegisteredV2ThroughTheirParent(marker: String) async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      _ = try await space.fs(.shared).write("/marker.txt", Data(marker.utf8), ifMatch: nil)
      let folder = try ScratchFolder("worker-v2-remote")
      let path = folder.url.appending(path: "remote.txt")
      try Data(marker.utf8).write(to: path)
      let (machine, _) = try await space.addMachineV2(name: "fixture-box-v2", group: .shared)
      let agent = try OperationAgent(machine: machine.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
      let hub = MachineHub(space: space)
      let coordinator = MachineV2Coordinator(space: space, key: SymmetricKey(size: .bits256), problemsGroup: .shared, origin: URL(string: "https://test.invalid")!, fetch: { _ in FetchClient { try await agent.handler($0) } }, abort: { _, _ in })
      let service = MachineV2Service(hub: MachineV2Hub(space: space), coordinator: coordinator, failure: nil)
      await hub.configureV2(service)
      let description = try await service.client(group: .shared).describe(machine.id.rawValue)
      try await space.recordMachineV2Presence(machine.id.rawValue, group: .shared, state: .attached, description: description)
      let handler = "import {machine} from 'wuhu:machine'; import {readText,writeText} from 'wuhu:space'; export default async ({rows,state,wake}) => { const {content}=await readText('/marker.txt'); await writeText('/handler-result.txt',content,{ifMatch:null}); wake(content); const machineText = await machine('fixture-box-v2').readText(\(JSONValue.string(path.path).jsonString())); return {marker:content,rows,state,machineText}; }"
      _ = try await space.fs(.shared).write("/handler.js", Data(handler.utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space, scriptMachines: .init(files: machineSeam(hub: hub), exec: execBackend(space: space, hub: hub)))
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await agent.run() }; defer { tasks.cancelAll() }
        let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime(space), machines: true, activity: { _ in }, exited: {})
        let result: Result<Void, any Error>
        do {
          let response = try await RemoteHandlerExecution(client: connection.client).executeHandler(.init(path: "/handler.js", session: id, rows: .init(columns: ["value"], decltypes: [nil], rows: [[.integer(7)]]), stateJSON: "{\"before\":true}"))
          #expect(response.wakes == [marker])
          let state = try #require(JSONValue.parse(response.stateJSON))
          #expect(state.object?["marker"] == .string(marker))
          #expect(state.object?["machineText"] == .string(marker))
          #expect(state.object?["rows"] == [["value": 7]])
          #expect(state.object?["state"] == ["before": true])
          #expect(try await space.fs(.shared).read("/handler-result.txt").1 == Data(marker.utf8))
          result = .success(())
        } catch { result = .failure(error) }
        await connection.stop(); await agent.shutdown(); await service.shutdown()
        try result.get()
      }
    }
  }

  @Test func cancellingHandlerBeforeReplyHeadersStopsQuickJSButKeepsChildUsable() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let source = "import {writeText} from 'wuhu:space'; export default async () => { await writeText('/entered.txt','yes',{ifMatch:null}); await sleep(60000); await writeText('/must-not-write.txt','no',{ifMatch:null}); return null; }"
      _ = try await space.fs(.shared).write("/blocked.js", Data(source.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/healthy.js", Data("export default async () => ({healthy:true})".utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime(space), activity: { _ in }, exited: {})
      let handler = RemoteHandlerExecution(client: connection.client)
      let pending = Task { try await handler.executeHandler(.init(path: "/blocked.js", session: id)) }
      let result: Result<Void, any Error>
      do {
        try await until("handler is running before headers", timeout: .seconds(20)) { (try? await space.fs(.shared).stat("/entered.txt")) != nil }
        pending.cancel()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        let response = try await handler.executeHandler(.init(path: "/healthy.js", session: id))
        #expect(response.stateJSON == "{\"healthy\":true}")
        #expect((try? await space.fs(.shared).stat("/must-not-write.txt")) == nil)
        result = .success(())
      } catch { result = .failure(error) }
      pending.cancel(); _ = await pending.result
      await connection.stop()
      try result.get()
    }
  }

  @Test func childCrashEndsHandlerAndReportsLostScriptWithoutMachineExec() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let source = "import {writeText} from 'wuhu:space'; export default async () => { await writeText('/entered.txt','once',{ifMatch:null}); await sleep(60000); await writeText('/must-not-write.txt','no',{ifMatch:null}); return null; }"
      _ = try await space.fs(.shared).write("/blocked.js", Data(source.utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let lost = Mutex<[String]>([])
      let callbacks = WorkerRuntimeOwner(attempts: .init(), scriptLost: { session, script in
        #expect(session == id)
        lost.withLock { $0.append(script) }
      }, usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: callbacks, activity: { _ in }, exited: {})
      let pending = Task { try await RemoteHandlerExecution(client: connection.client).executeHandler(.init(path: "/blocked.js", session: id)) }
      let result: Result<Void, any Error>
      do {
        try await until("handler enters before child crash", timeout: .seconds(20)) { (try? await space.fs(.shared).stat("/entered.txt")) != nil }
        #expect(kill(connection.processID, SIGKILL) == 0)
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        await connection.lifetime.value
        #expect(lost.withLock { $0.count } == 1)
        #expect(lost.withLock { $0.first?.hasPrefix("handler-") } == true)
        #expect((try? await space.fs(.shared).stat("/must-not-write.txt")) == nil)
        #expect(try await space.fs(.shared).read("/entered.txt").1 == Data("once".utf8))
        result = .success(())
      } catch { result = .failure(error) }
      pending.cancel(); _ = await pending.result
      await connection.stop()
      try result.get()
    }
  }

  @Test func longOwnerStreamsDoNotStarveFurtherEffects() async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await session(space)
      let source = "import {observe,writeText} from 'wuhu:space'; export default async () => { const streams=Array.from({length:12},()=>observe('SELECT 1 AS value')[Symbol.asyncIterator]()); await Promise.all(streams.map(s=>s.next())); await writeText('/after-streams.txt','ready',{ifMatch:null}); await Promise.all(streams.map(s=>s.return())); return {ready:true}; }"
      _ = try await space.fs(.shared).write("/streams.js", Data(source.utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime(space), activity: { _ in }, exited: {})
      let result: Result<Void, any Error>
      do {
        let response = try await RemoteHandlerExecution(client: connection.client).executeHandler(.init(path: "/streams.js", session: id))
        #expect(response.stateJSON == "{\"ready\":true}")
        #expect(try await space.fs(.shared).read("/after-streams.txt").1 == Data("ready".utf8))
        result = .success(())
      } catch { result = .failure(error) }
      await connection.stop()
      try result.get()
    }
  }

  @Test func detachedScriptWithoutExecReceivesOneLossNotificationAndIsNeverReplayed() async throws {
    try await withSessionDeps {
      let calls = Mutex(0)
      let source = "import {writeText} from 'wuhu:space'; await writeText('/detached-entered.txt','once',{ifMatch:null}); result('detached'); await sleep(600000); await writeText('/must-not-write.txt','no',{ifMatch:null})"
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        let round = calls.withLock { $0 += 1; return $0 }
        let block: JSONValue = round == 1 ? ["type": "tool_use", "id": "detached-script", "name": "run_script", "input": [:]] : ["type": "text", "text": ""]
        let delta: JSONValue = round == 1 ? ["type": "input_json_delta", "partial_json": .string(JSONValue.object(["source": .string(source), "timeout_seconds": 600]).jsonString())] : ["type": "text_delta", "text": "detached complete"]
        let events: [(String, JSONValue)] = [
          ("message_start", ["message": ["usage": ["input_tokens": 10]]]),
          ("content_block_start", ["index": 0, "content_block": block]),
          ("content_block_delta", ["index": 0, "delta": delta]),
          ("content_block_stop", ["index": 0]),
          ("message_delta", ["delta": ["stop_reason": .string(round == 1 ? "tool_use" : "end_turn")], "usage": ["output_tokens": 1]]),
          ("message_stop", [:]),
        ]
        return .init(status: .ok, body: .bytes(Data(events.map { "event: \($0.0)\ndata: \($0.1.jsonString())\n\n" }.joined().utf8), contentType: "text/event-stream"))
      })
      let space = try Space.inMemory()
      let port = try #require(provider.localAddress?.port)
      _ = try await space.fs(.shared).write("/models.json", Data("{\"offline\":{\"dialect\":\"anthropic\",\"baseURL\":\"http://127.0.0.1:\(port)\",\"opaqueReplay\":\"none\",\"models\":{\"small\":{\"maxInput\":100000,\"maxOutput\":1000,\"efforts\":[\"none\"],\"defaultEffort\":\"none\"}}}}".utf8), ifMatch: nil)
      let id = try await session(space)
      let owner = InProcessToolOwnerClient(space: space, executionOwner: InProcessExecutionOwnerClient(space: space, credentials: .init { _ in .apiKey("fixture") }))
      let callbacks = WorkerRuntimeOwner(attempts: .init(), scriptLost: lostWorkerScript(owner: owner), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
      let connection = try await WorkerConnection.start(executable: binary(), owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: callbacks, activity: { _ in }, exited: {})
      let result: Result<Void, any Error>
      do {
        _ = try await RemoteSessionExecution(client: connection.client).enqueue(.notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("fixture"), content: .init(text: "detach script"))), to: id)
        // The flow takes about a second alone but stretches past 20 s on a pool
        // host running the whole check. The script's sleep and timeout_seconds
        // lie past the suite's 2 min cap, so no starvation can make the call
        // detach into a third provider round or end the script before SIGKILL;
        // this 90 s poll only bounds a hang.
        try await until("detached script returned but remains alive", timeout: .seconds(90)) {
          try await space.sessions.transcript(id).items.contains { if case let .assistant(entry) = $0 { entry.content.contains(.text("detached complete")) } else { false } }
        }
        #expect(try await space.fs(.shared).read("/detached-entered.txt").1 == Data("once".utf8))
        #expect(kill(connection.processID, SIGKILL) == 0)
        await connection.lifetime.value
        let hydration = try await space.sessions.hydrate(id)
        let notices = hydration.undrained.compactMap { item -> String? in
          guard case let .notification(notification) = item.input, notification.kind == .script else { return nil }
          return notification.content.text
        }
        #expect(notices.count == 1)
        #expect(notices.first?.contains("effects are unknown") == true)
        #expect(notices.first?.contains("will not be retried automatically") == true)
        #expect(calls.withLock { $0 } == 2)
        #expect((try? await space.fs(.shared).stat("/must-not-write.txt")) == nil)
        result = .success(())
      } catch { result = .failure(error) }
      await connection.stop(); await provider.shutdown()
      try result.get()
    }
  }
}
