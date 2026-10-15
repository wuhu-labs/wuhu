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
import ExecutionOwner
import InferenceKit
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(2))) struct ExecutionWorkerParentQuiescenceTests {
  @Test func boundParentQuiescesAndResumesTheSameLiveWorkerBeforeOwnerEffects() async throws {
    try await withSessionDeps {
      let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "quiescence", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let source = """
      import {readText,writeText} from 'wuhu:space';
      export default async () => {
        const previous = await readText('/effects.txt');
        const value = Number(previous.content) + 1;
        await writeText('/effects.txt',String(value),{ifMatch:previous.token});
        return {value};
      }
      """
      _ = try await space.fs(.shared).write("/effects.txt", Data("0".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/effect.js", Data(source.utf8), ifMatch: nil)
      let owner = InProcessToolOwnerClient(space: space)
      let exits = Mutex(0)
      let runtime = WorkerRuntimeOwner(attempts: .init(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
      let connection = try await WorkerConnection.start(executable: executable, owner: owner, spawn: { try await owner.spawn($0, $1, $2) }, runtime: runtime, activity: { _ in }, exited: { exits.withLock { $0 += 1 } })
      let result: Result<Void, any Error>
      do {
        let handoff = try #require(connection.ownerHandoff)
        let handlers = RemoteHandlerExecution(client: connection.client)
        let first = try await handlers.executeHandler(.init(path: "/effect.js", session: id))
        #expect(JSONValue.parse(first.stateJSON) == ["value": 1])
        await first.acknowledge()
        try await handoff.prepare()
        #expect(kill(connection.processID, 0) == 0)
        _ = try await RemoteSessionExecution(client: connection.client).inventory()
        #expect(exits.withLock { $0 } == 0)
        #expect(try await space.fs(.shared).read("/effects.txt").1 == Data("1".utf8))
        try await handoff.resume()
        await connection.ownerTransport?.detach()
        let second = try await handlers.executeHandler(.init(path: "/effect.js", session: id))
        #expect(JSONValue.parse(second.stateJSON) == ["value": 2])
        #expect(try await space.fs(.shared).read("/effects.txt").1 == Data("2".utf8))
        await second.acknowledge()
        try await handoff.prepare()
        try await handoff.resume()
        #expect(kill(connection.processID, 0) == 0)
        #expect(exits.withLock { $0 } == 0)
        result = .success(())
      } catch { result = .failure(error) }
      await connection.stop()
      #expect(exits.withLock { $0 } == 1)
      try result.get()
    }
  }
}
