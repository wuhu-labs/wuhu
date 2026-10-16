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
import Clocks
import Dependencies
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import SessionDomain
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct DeferredAttemptTerminationTests {
  @Test(arguments: [false, true], [false, true]) func expiredPublicationTerminatesOriginalAttemptWithoutReplay(adopted: Bool, terminalBeforeFlush: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let space = try Space.inMemory(), originalHub = AttemptHub(), successorHub = AttemptHub()
      let owner = InProcessExecutionOwnerClient(space: space)
      let source = ParentExecutionHandoff(owner: owner, runtime: runtime(originalHub))
      let endpoint = try await source.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
      let current = Mutex(endpoint), unknownCalls = Mutex(0)
      let fetch = FetchClient { incoming in
        var request = incoming
        if request.url.path == "/worker/upload", let bytes = try await request.body?.data() {
          if let publication = try? JSONDecoder().decode(AttemptPublication.self, from: bytes), case .unknown(_, .handoffFenceExpired) = publication.event { unknownCalls.withLock { $0 += 1 } }
          request.body = .bytes(bytes)
        }
        return try await current.withLock { $0 }.handler(request)
      }
      let client = try WorkerClient(socket: "/private/attempt-expiry.sock", token: "fixture", control: fetch, bytes: fetch)
      _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
      let rpc = OwnerRPC(client: client), relay = DeferredAttemptTerminations(), id = UUID(), token = UUID()
      let session = SessionID("pony-crane-moon")
      try await relay.publish(session: session, event: .started(attemptID: id), rpc: rpc)
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      await clock.advance(by: .seconds(2))
      await #expect(throws: WorkerProtocolError(.handoffTimedOut, message: "Worker owner transaction fence timed out")) {
        try await relay.publish(session: session, event: .delta(attemptID: id, event: .start(AssistantMessage())), rpc: rpc)
      }
      #expect(await relay.pendingCount == 1)
      if terminalBeforeFlush { try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "must not replace outcome-unknown")), rpc: rpc) }
      try await source.prepare()
      let ready: ParentExecutionHandoff
      let hub: AttemptHub
      if adopted {
        let identity = ParentExecutionIdentity(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 123, birth: "fixture-process-birth")
        let transfer = try await source.exportExec(identity: identity)
        let descriptor = dup(transfer.descriptor)
        _ = try #require(descriptor >= 0)
        ready = try await ParentExecTransfer.take(descriptor, expecting: identity, owner: owner, runtime: runtime(successorHub))
        try await ready.commitExec()
        let replacement = try await ready.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "successor"))
        current.withLock { $0 = replacement }
        try await client.reconnect()
        hub = successorHub
      } else {
        try await source.resume()
        ready = source
        hub = originalHub
      }
      #expect(Set(hub.inFlight(session: session).keys) == [id])
      let events = hub.events(session: session)
      try await client.resumeOwnerTransactions(token)
      async let first: Void = relay.flush(using: rpc)
      async let second: Void = relay.flush(using: rpc)
      _ = try await (first, second)
      #expect(hub.inFlight(session: session).isEmpty)
      #expect(unknownCalls.withLock { $0 } == 1)
      if !terminalBeforeFlush { try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "late terminal")), rpc: rpc) }
      #expect(await relay.pendingCount == 0)
      try await relay.flush(using: rpc)
      #expect(unknownCalls.withLock { $0 } == 1)
      var iterator = events.makeAsyncIterator()
      guard case let .finished(terminal, .failed(reason))? = await iterator.next() else { Issue.record("Missing unknown-outcome terminal"); return }
      #expect(terminal == id && reason == "unknownOutcome: parent execution handoff fence expired")
      try await ready.prepare()
      try await ready.resume()
      await ready.shutdown()
      if adopted { await source.shutdown() }
    }
  }

  @Test func resumeJoinsPublicationExpiryRaceBeforeReturning() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let space = try Space.inMemory(), hub = AttemptHub(), session = SessionID("pony-crane-moon")
      let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime(hub))
      let client = try await client(source), relay = DeferredAttemptTerminations(), rpc = OwnerRPC(client: client), id = UUID(), token = UUID()
      try await relay.publish(session: session, event: .started(attemptID: id), rpc: rpc)
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      let publication = Task { try await relay.publish(session: session, event: .delta(attemptID: id, event: .start(AssistantMessage())), rpc: rpc) }
      for _ in 0 ..< 10000 {
        if await relay.publishingCount == 1 { break }
        await Task.yield()
      }
      _ = try #require(await relay.publishingCount == 1)
      await clock.advance(by: .seconds(2))
      try await client.resumeOwnerTransactions(token)
      try await relay.flush(using: rpc)
      await #expect(throws: WorkerProtocolError(.handoffTimedOut, message: "Worker owner transaction fence timed out")) { try await publication.value }
      #expect(hub.inFlight(session: session).isEmpty)
      try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "late terminal")), rpc: rpc)
      #expect(await relay.pendingCount == 0)
      await source.shutdown()
    }
  }

  @Test(arguments: [false, true]) func retainedNoticeCapacityRefusesBeforeAnotherAttemptStarts(terminalObserved: Bool) async throws {
    #expect(DeferredAttemptTerminations.capacity == 4096)
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let space = try Space.inMemory(), hub = AttemptHub(), session = SessionID("pony-crane-moon")
      let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime(hub))
      let client = try await client(source), relay = DeferredAttemptTerminations(capacity: 2), rpc = OwnerRPC(client: client)
      let ids = [UUID(), UUID()], token = UUID()
      for id in ids { try await relay.publish(session: session, event: .started(attemptID: id), rpc: rpc) }
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      await clock.advance(by: .seconds(2))
      for id in ids {
        let event: AttemptEvent = terminalObserved ? .finished(attemptID: id, outcome: .failed(reason: "expired")) : .delta(attemptID: id, event: .start(AssistantMessage()))
        await #expect(throws: WorkerProtocolError.self) { try await relay.publish(session: session, event: event, rpc: rpc) }
      }
      #expect(await relay.pendingCount == 2)
      await #expect(throws: WorkerProtocolError(.capacityExceeded, message: "Too many tracked worker attempts")) {
        try await relay.publish(session: session, event: .started(attemptID: UUID()), rpc: rpc)
      }
      #expect(Set(hub.inFlight(session: session).keys) == Set(ids))
      try await client.resumeOwnerTransactions(token)
      try await relay.flush(using: rpc)
      #expect(await relay.pendingCount == (terminalObserved ? 0 : 2))
      #expect(hub.inFlight(session: session).isEmpty)
      if !terminalObserved {
        await #expect(throws: WorkerProtocolError(.capacityExceeded, message: "Too many tracked worker attempts")) {
          try await relay.publish(session: session, event: .started(attemptID: UUID()), rpc: rpc)
        }
        for id in ids { try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "late terminal")), rpc: rpc) }
        #expect(await relay.pendingCount == 0)
      }
      await source.shutdown()
    }
  }

  @Test func olderPeerGetsTypedRefusalBeforeUnknownTerminalBytesAreSent() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let current = ExecutionWorkerBootstrap.hello(release: "current")
      let older = WorkerHello(capabilities: current.capabilities.subtracting([ExecutionWorkerBootstrap.attemptUnknownCapability]), required: current.required, release: "older")
      let space = try Space.inMemory(), hub = AttemptHub(), session = SessionID("pony-crane-moon")
      let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime(hub))
      let client = try await client(source, hello: older), relay = DeferredAttemptTerminations(), rpc = OwnerRPC(client: client), id = UUID(), token = UUID()
      try await relay.publish(session: session, event: .started(attemptID: id), rpc: rpc)
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      await clock.advance(by: .seconds(2))
      await #expect(throws: WorkerProtocolError.self) { try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "expired")), rpc: rpc) }
      try await client.resumeOwnerTransactions(token)
      await #expect(throws: WorkerProtocolError(.missingCapability, message: "Missing execution capability: " + ExecutionWorkerBootstrap.attemptUnknownCapability)) { try await relay.flush(using: rpc) }
      #expect(await relay.pendingCount == 1)
      #expect(Set(hub.inFlight(session: session).keys) == [id])
      #expect(await client.pendingReceipts().isEmpty)
      await source.shutdown()
    }
  }

  @Test(arguments: [false, true]) func sameTokenResumeRetriesFailedRepairUntilAcknowledged(cancel: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let space = try Space.inMemory(), hub = AttemptHub(), session = SessionID("pony-crane-moon")
      let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime(hub))
      let client = try await client(source), relay = DeferredAttemptTerminations(), rpc = OwnerRPC(client: client), id = UUID(), token = UUID()
      try await relay.publish(session: session, event: .started(attemptID: id), rpc: rpc)
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      await clock.advance(by: .seconds(2))
      await #expect(throws: WorkerProtocolError.self) { try await relay.publish(session: session, event: .finished(attemptID: id, outcome: .failed(reason: "expired")), rpc: rpc) }
      let calls = Mutex(0)
      let repair: @Sendable () async throws -> Void = {
        let attempt = calls.withLock { $0 += 1; return $0 }
        if attempt <= 2 {
          if cancel { throw CancellationError() }
          throw WorkerProtocolError(.unavailable, message: "injected repair failure")
        }
        try await relay.flush(using: rpc)
      }
      await #expect(throws: (any Error).self) { try await client.resumeOwnerTransactions(token, afterResume: repair) }
      #expect(try await client.withOwnerTransaction { true })
      #expect(Set(hub.inFlight(session: session).keys) == [id])
      let commands = try OwnerByteEndpoint(invoke: { call in
        try await ownerReply {
          try await client.resumeOwnerTransactions(ownerDecode(UUID.self, call.payload), afterResume: repair)
          return .bool(true)
        }
      }).endpoint(token: "fixture", hello: ExecutionWorkerBootstrap.hello(release: "worker"))
      let fetch = FetchClient(fetch: commands.handler)
      let controller = try WorkerClient(socket: "/private/resume-repair.sock", token: "fixture", control: fetch, bytes: fetch)
      _ = try await controller.negotiate(ExecutionWorkerBootstrap.hello(release: "parent"))
      try await withDependencies { $0.continuousClock = ImmediateClock() } operation: {
        try await RemoteSessionExecution(client: controller).resumeExec(token)
      }
      #expect(hub.inFlight(session: session).isEmpty)
      #expect(await relay.pendingCount == 0)
      #expect(try await !client.resumeOwnerTransactions(token, afterResume: repair))
      #expect(calls.withLock { $0 } == 3)
      await source.shutdown()
    }
  }

  @Test(arguments: [false, true]) func expiredActivityReleaseIsReconciledBeforeResumeAcknowledges(adopted: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let space = try Space.inMemory(), owner = InProcessExecutionOwnerClient(space: space)
      let leases = Mutex<Set<UUID>>([]), calls = Mutex<[Bool]>([])
      let control: @Sendable (WorkerCall) async throws -> JSONValue = { call in
        let activity = try ExecutionWorkerActivity(call: call)
        leases.withLock { if activity.active { $0.insert(activity.pass) } else { $0.remove(activity.pass) } }
        calls.withLock { $0.append(activity.active) }
        return try await ownerReply { .bool(true) }
      }
      let source = ParentExecutionHandoff(owner: owner, control: control)
      let endpoint = try await source.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "source"))
      let current = Mutex(endpoint)
      let fetch = FetchClient { request in try await current.withLock { $0 }.handler(request) }
      let client = try WorkerClient(socket: "/private/activity-expiry.sock", token: "fixture", control: fetch, bytes: fetch)
      _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
      let relay = DeferredActivityReleases(capacity: 1), rpc = OwnerRPC(client: client), token = UUID(), pass = UUID(), session = SessionID("pony-crane-moon")
      try await relay.publish(.init(session: session, pass: pass, active: true), rpc: rpc)
      try await client.pauseOwnerTransactions(token, drainTimeout: .seconds(1), waitTimeout: .seconds(2))
      await clock.advance(by: .seconds(2))
      try await relay.publish(.init(session: session, pass: pass, active: false), rpc: rpc)
      #expect(await relay.pendingCount == 1)
      #expect(leases.withLock { $0 } == [pass])
      await #expect(throws: WorkerProtocolError(.capacityExceeded, message: "Too many tracked worker passes")) {
        try await relay.publish(.init(session: session, pass: UUID(), active: true), rpc: rpc)
      }
      try await source.prepare()
      let ready: ParentExecutionHandoff
      if adopted {
        ready = try await source.transfer(to: owner, control: control)
        try await ready.resume()
      } else { ready = source; try await source.resume() }
      if adopted {
        let replacement = try await ready.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "successor"))
        current.withLock { $0 = replacement }
        try await client.reconnect()
      }
      try await client.resumeOwnerTransactions(token, afterResume: { try await relay.flush(using: rpc) })
      #expect(leases.withLock { $0.isEmpty })
      #expect(await relay.pendingCount == 0)
      #expect(calls.withLock { $0 } == [true, false])
      let next = UUID()
      try await relay.publish(.init(session: session, pass: next, active: true), rpc: rpc)
      try await relay.publish(.init(session: session, pass: next, active: false), rpc: rpc)
      #expect(leases.withLock { $0.isEmpty })
      try await ready.prepare()
      try await ready.resume()
      await ready.shutdown()
    }
  }

  private func runtime(_ attempts: AttemptHub) -> WorkerRuntimeOwner {
    .init(attempts: attempts, usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
  }

  private func client(_ handoff: ParentExecutionHandoff, hello: WorkerHello = ExecutionWorkerBootstrap.hello(release: "parent")) async throws -> WorkerClient {
    let endpoint = try await handoff.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: hello)
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/deferred-attempt.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}
