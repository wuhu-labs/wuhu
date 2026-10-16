#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import JSONValue
import Scratch
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

private struct OwnershipHandler: HandlerExecutionClient {
  let execute: @Sendable (ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await execute(invocation) }
}

private enum HandlerOutcome: CaseIterable { case completed, discarded, unknown }

@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct ExecutionWorkerHandlerOwnershipTests {
  @Test(arguments: HandlerOutcome.allCases) fileprivate func handlerOwnershipAfterReopen(outcome: HandlerOutcome) async throws {
    try await withSessionDeps {
      let folder = try ScratchFolder("handler-worker-ownership")
      defer { folder.remove() }
      let file = folder.url.appendingPathComponent("space.sqlite")
      let space = try Space.open(file: file)
      let session = try await space.sessions.createSession(group: .shared, title: "handler", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let started = Mutex<UUID?>(nil)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, startConnection: { incarnation, _, _ in
        started.withLock { $0 = incarnation }
        let handler = WorkerHandlerEndpoint(handler: OwnershipHandler { invocation in
          #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [session])
          if outcome == .unknown { throw WorkerProtocolError(.unknownOutcome, message: "reply lost") }
          let script = "handler-" + invocation.id.uuidString
          try await space.sessions.registerWorkerScript(script, session: session, incarnation: incarnation)
          if outcome == .discarded { throw WorkerProtocolError(.remoteFailure, message: "handler discarded") }
          try await space.sessions.releaseWorkerScript(script, session: session, incarnation: incarnation)
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
      let invocation = ScriptHandlerInvocation(path: "/handler.js", session: session)
      if outcome != .completed {
        await #expect(throws: WorkerProtocolError.self) { try await worker.executeHandler(invocation) }
      } else {
        let first = try await worker.executeHandler(invocation)
        let second = try await worker.executeHandler(.init(path: "/handler.js", session: session))
        let incarnation = try #require(started.withLock { $0 })
        await first.acknowledge()
        #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [session])
        await worker.shutdown()
        await Task {
          withUnsafeCurrentTask { $0?.cancel() }
          await second.acknowledge()
        }.value
      }
      let incarnation = try #require(started.withLock { $0 })
      if outcome == .discarded {
        #expect(try await space.sessions.sessionsOwnedByWorkers([incarnation]) == [session])
        try await space.sessions.releaseWorkerScript("handler-" + invocation.id.uuidString, session: session, incarnation: incarnation)
      }
      // Reopening before graceful teardown models losing the parent without cleanup.
      let reopened = try Space.open(file: file)
      let manifest = ExecutionWorkerManifest(version: 1, space: try await reopened.identity().rawValue, generation: UUID(), incarnation: incarnation, processID: 123, birth: "fixture", credentials: .init(current: String(repeating: "a", count: 72)))
      let admission = try await ExecutionWorkerBootReconciliation.prepare(sessions: reopened.sessions) {
        .init(unresolved: [incarnation], unresolvedWorkers: [.init(manifest: manifest, directory: "/private/worker", reason: .unconfirmed)], credentials: .init())
      }
      #expect(admission.blockedSessions == (outcome == .unknown ? [session] : []))
      await worker.shutdown()
    }
  }
}
