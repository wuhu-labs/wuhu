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
import AsyncHTTPClient
import ExecutionOwner
import Fetch
import FetchAsyncHTTPClient
import JSONValue
import NIOPosix
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.sessionFixtures(timeLimit: .minutes(2))) struct ExecutionWorkerParentReplacementTests {
  private func runtime() -> WorkerRuntimeOwner {
    .init(attempts: .init(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
  }

  private func seed(_ space: Space, value: Int) async throws -> SessionID {
    let id = try await space.sessions.createSession(group: .shared, title: "replacement", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    _ = try await space.fs(.shared).write("/effects.txt", Data(String(value).utf8), ifMatch: nil)
    let source = """
    import {readText,writeText} from 'wuhu:space';
    export default async ({wake}) => {
      const previous = await readText('/effects.txt');
      const value = Number(previous.content) + 1;
      await writeText('/effects.txt',String(value),{ifMatch:previous.token});
      wake('once');
      return {value};
    }
    """
    _ = try await space.fs(.shared).write("/effect.js", Data(source.utf8), ifMatch: nil)
    return id
  }

  @Test func serializedReplacementRebindsServicesPreservesBothReceiptJournalsAndOwnsFinalCleanup() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let originalSpace = try Space.inMemory(), replacementSpace = try Space.inMemory()
      let originalSession = try await seed(originalSpace, value: 0)
      let replacementSession = try await seed(replacementSpace, value: 100)
      let original = InProcessToolOwnerClient(space: originalSpace)
      let replacement = InProcessToolOwnerClient(space: replacementSpace)
      let originalActivities = Mutex(0), replacementActivities = Mutex(0), exits = Mutex(0)
      let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
      let connection = try await WorkerConnection.start(executable: executable, owner: original, spawn: { try await original.spawn($0, $1, $2) }, runtime: runtime(), persistence: fixture.persistence, activity: { _ in originalActivities.withLock { $0 += 1 } }, exited: { exits.withLock { $0 += 1 } })
      let http = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
      let (entered, signal) = AsyncStream<Void>.makeStream()
      let (release, finish) = AsyncStream<Void>.makeStream()
      defer { finish.finish() }
      let cancelled = Mutex(false)
      var pending: Task<Void, any Error>?
      let outcome: Result<Void, any Error>
      do {
        let binding = try #require(connection.parentBinding)
        let (_, manifest) = try await fixture.manifest()
        let socket = try #require(manifest.sockets).parent
        var before = stat()
        #expect(lstat(socket, &before) == 0)
        let probe = try WorkerClient(socket: socket, token: manifest.credentials.current, control: .asyncHTTPClient(http, timeout: nil), bytes: .asyncHTTPClient(http, timeout: nil))
        _ = try await probe.negotiate(ExecutionWorkerBootstrap.hello(release: "replacement-fixture"))
        let activity = try ExecutionWorkerActivity(session: originalSession, pass: UUID(), active: false).call()
        let retained = try #require(try await probe.retaining(activity))
        let input = WorkerCall(id: retained.id, operation: "owner.input", payload: .string(retained.operation), receipt: retained.receipt)
        let output = WorkerCall(id: retained.id, operation: "owner.output", payload: .string(retained.operation), receipt: retained.receipt)
        try await probe.upload(input, body: .json(retained.payload))
        #expect(originalActivities.withLock { $0 } == 1)
        let handlers = RemoteHandlerExecution(client: connection.client)
        let firing = UUID()
        let first = try await handlers.executeHandler(.init(id: firing, path: "/effect.js", session: originalSession))
        #expect(JSONValue.parse(first.stateJSON) == ["value": 1])
        #expect(first.wakes == ["once"])
        let handlerCall = try #require(await connection.client.pendingReceipts().first { $0.id == firing })
        let definition = try #require(try await probe.retaining(.init(operation: "script.observe-open", payload: ["sql": "SELECT path FROM docs", "parameters": [], "session": .string(originalSession.rawValue)])))
        try await probe.upload(.init(id: definition.id, operation: "owner.input", payload: .string(definition.operation), receipt: definition.receipt), body: .json(definition.payload))
        let opened = try await probe.stream(.init(id: definition.id, operation: "owner.output", payload: .string(definition.operation), receipt: definition.receipt)).json(WorkerReply.self)
        let readerID = try #require(opened.result?.object?["value"]?.stringValue)
        let pull = try #require(try await probe.retaining(.init(operation: "script.stream-next", payload: ["id": .string(readerID)])))
        try await probe.upload(.init(id: pull.id, operation: "owner.input", payload: .string(pull.operation), receipt: pull.receipt), body: .json(pull.payload))
        let readerOutput = WorkerCall(id: pull.id, operation: "owner.output", payload: .string(pull.operation), receipt: pull.receipt)
        let readerReply = try await probe.stream(readerOutput).json(WorkerReply.self)
        try await binding.prepare()
        await #expect(throws: WorkerProtocolError.self) { try await binding.replaceSerialized(owner: InProcessExecutionOwnerClient(space: replacementSpace), control: { _ in .null }) }
        try await probe.reconnect()
        try await probe.upload(input, body: .json(retained.payload))
        #expect(originalActivities.withLock { $0 } == 1)
        #expect(try await probe.stream(readerOutput).json(WorkerReply.self) == readerReply)
        try await binding.prepare()
        await #expect(throws: WorkerProtocolError.self) { try await probe.reconnect() }
        try await binding.replaceSerialized(owner: replacement, runtime: runtime(), spawn: .init(spawn: { try await replacement.spawn($0, $1, $2) }), control: { _ in
          replacementActivities.withLock { $0 += 1 }
          return .object(["value": .bool(true), "fault": .null])
        })
        try await probe.reconnect()
        #expect(try await probe.stream(readerOutput).json(WorkerReply.self) == readerReply)
        for receipt in [definition.receipt, pull.receipt] {
          let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(try #require(receipt)))
          _ = try await probe.call(.init(operation: "owner.ack", payload: payload))
        }
        try await probe.upload(input, body: .json(retained.payload))
        let recovered = try await probe.stream(output).json(WorkerReply.self)
        #expect(recovered.id == retained.id && recovered.error == nil)
        #expect(recovered.result == .object(["value": .bool(true), "fault": .null]))
        #expect(originalActivities.withLock { $0 } == 1)
        #expect(replacementActivities.withLock { $0 } == 0)
        let acknowledgement = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(try #require(retained.receipt)))
        _ = try await probe.call(.init(operation: "owner.ack", payload: acknowledgement))
        let replayInput = WorkerCall(id: firing, operation: "owner.input", payload: .string("handler.execute"), receipt: handlerCall.receipt)
        let invocation: JSONValue = ["path": "/effect.js", "session": .string(originalSession.rawValue)]
        try await connection.client.upload(replayInput, body: .json(invocation))
        let replayOutput = WorkerCall(id: firing, operation: "owner.output", payload: .string("handler.execute"), receipt: handlerCall.receipt)
        let replay = try await connection.client.stream(replayOutput).json(WorkerReply.self)
        #expect(replay.result == .object(["value": .object(["stateJSON": .string(first.stateJSON), "wakes": .array(first.wakes.map(JSONValue.string))])]))
        await first.acknowledge()
        let second = try await handlers.executeHandler(.init(path: "/effect.js", session: replacementSession))
        #expect(JSONValue.parse(second.stateJSON) == ["value": 101])
        await second.acknowledge()
        #expect(try await originalSpace.fs(.shared).read("/effects.txt").1 == Data("1".utf8))
        #expect(try await replacementSpace.fs(.shared).read("/effects.txt").1 == Data("101".utf8))
        try await ExecutionWorkerActivity(session: replacementSession, pass: UUID(), active: false).publish(using: probe)
        #expect(replacementActivities.withLock { $0 } == 1)
        try await binding.prepare()
        try await binding.replaceSerialized(owner: replacement, runtime: runtime(), spawn: .init(spawn: { try await replacement.spawn($0, $1, $2) }), control: { _ in
          defer { cancelled.withLock { $0 = Task.isCancelled } }
          signal.yield(())
          for await _ in release {}
          try Task.checkCancellation()
          return .bool(true)
        })
        try await probe.reconnect()
        var after = stat()
        #expect(lstat(socket, &after) == 0 && after.st_ino == before.st_ino && after.st_dev == before.st_dev)
        #expect(kill(connection.processID, 0) == 0)
        #expect(manifest.processID == connection.processID)
        #expect(try processBirthIdentity(connection.processID) == manifest.birth)
        #expect(exits.withLock { $0 } == 0)
        let held = try #require(try await probe.retaining(ExecutionWorkerActivity(session: replacementSession, pass: UUID(), active: false).call()))
        let heldInput = WorkerCall(id: held.id, operation: "owner.input", payload: .string(held.operation), receipt: held.receipt)
        pending = Task { try await probe.upload(heldInput, body: .json(held.payload)) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        await connection.stop()
        await #expect(throws: (any Error).self) { try await pending?.value }
        #expect(cancelled.withLock { $0 })
        await #expect(throws: WorkerProtocolError.self) { try await binding.prepare() }
        outcome = .success(())
      } catch { outcome = .failure(error) }
      await connection.stop()
      pending?.cancel()
      _ = await pending?.result
      try? await http.shutdown()
      #expect(exits.withLock { $0 } == 1)
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.persistence.runtimeRoot).isEmpty)
      try outcome.get()
    }
  }
}
