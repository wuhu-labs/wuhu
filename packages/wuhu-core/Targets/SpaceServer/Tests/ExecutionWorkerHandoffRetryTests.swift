#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import JSONValue
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerHandoffRetryTests {
  @Test(arguments: [true, false]) func handoffRetainsOwnershipUntilYieldAndDestinationWakeRecover(failYield: Bool) async throws {
    try await withSessionDeps {
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "retry handoff", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let starts = Mutex(0)
      let incarnations = Mutex<[UUID]>([])
      let yields = Mutex(0)
      let destinationWakes = Mutex(0)
      let oldWakes = Mutex(0)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { incarnation, _, _ in
        incarnations.withLock { $0.append(incarnation) }
        let generation = starts.withLock { $0 += 1; return $0 }
        let bootstrap = ExecutionWorkerBootstrap.hello(release: "fixture")
        let legacyHello = WorkerHello(capabilities: bootstrap.capabilities.subtracting(["owner.continuity.v1"]), required: bootstrap.required, release: "fixture")
        let endpoint = try WorkerEndpoint(token: "fixture", hello: legacyHello, invoke: { _ in .null }, upload: { _, body in try await body.discard() }, download: { call in
          if call.operation == "execution.yield-assignment" {
            #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [id])
            let count = yields.withLock { $0 += 1; return $0 }
            if failYield, count <= 4 { throw WorkerProtocolError(.remoteFailure, message: "owner temporarily unavailable") }
          }
          if call.operation == "execution.wake" {
            if generation == 1 { oldWakes.withLock { $0 += 1 } }
            else {
              let count = destinationWakes.withLock { $0 += 1; return $0 }
              if !failYield, count <= 4 { throw WorkerProtocolError(.remoteFailure, message: "destination temporarily unavailable") }
            }
          }
          return try .json(JSONValue.object(["value": true]))
        })
        let fetch = FetchClient { try await endpoint.handler($0) }
        let client = try WorkerClient(socket: "/tmp/fixture.sock", token: "fixture", control: fetch, bytes: fetch)
        _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "fixture"))
        let lifetime = Task { let (stream, continuation) = AsyncStream<Void>.makeStream(); for await _ in stream {}; continuation.finish() }
        return WorkerConnection(processID: Int32(generation), client: client, lifetime: lifetime)
      })
      let result: Result<Void, any Error>
      do {
        try await worker.wake(id)
        try await worker.replaceGeneration()
        try await until("handoff recovers after more than three transient failures") { await worker.generationCount == 1 && destinationWakes.withLock { $0 } >= (failYield ? 1 : 5) }
        let owners = incarnations.withLock { $0 }
        #expect(owners.count == 2)
        #expect(try await space.sessions.sessionsOwnedByWorkers([owners[0]]) == [])
        #expect(try await space.sessions.sessionsOwnedByWorkers([owners[1]]) == [id])
        #expect(yields.withLock { $0 } == (failYield ? 5 : 1))
        #expect(oldWakes.withLock { $0 } == 1)
        try await worker.wake(id)
        #expect(destinationWakes.withLock { $0 } == (failYield ? 2 : 6))
        result = .success(())
      } catch { result = .failure(error) }
      await worker.shutdown()
      try result.get()
    }
  }
}
