#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import ServerTelemetry
import SessionDomain
import SessionTools
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct OwnerContinuityTests {
  @Test(arguments: ["/worker/upload", "/worker/download"], [false, true]) func lostAcknowledgementOrReplyResumesOneEffectAndAckFencesDelayedOriginal(lostPath: String, shutdownResponse: Bool) async throws {
    let context = try #require(ServerTracing.$emitter.withValue({ _ in }) {
      ServerSpan(.turn, session: "fixture", group: "shared").context
    })
    let effects = Mutex(0)
    let dropped = Mutex(false)
    let original = Mutex<WorkerCall?>(nil)
    let bytes = OwnerByteEndpoint(invoke: { call in
      #expect(call.traceContext == context)
      #expect(ServerTracing.context == context)
      effects.withLock { $0 += 1 }
      return try ownerEncode(OwnerEnvelope(value: .integer(7), fault: nil))
    })
    let endpoint = try bytes.endpoint(token: "token", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient { request in
      if request.url.path == "/worker/upload", let raw = request.headers["X-Wuhu-Worker-Stream"], let data = Data(base64Encoded: raw) {
        let call = try JSONDecoder().decode(WorkerCall.self, from: data)
        original.withLock { $0 = call }
      }
      let response = try await endpoint.handler(request)
      if request.url.path == lostPath, dropped.withLock({ flag in defer { flag = true }; return !flag }) {
        try await response.body.discard()
        if shutdownResponse { return .text("500 Internal Server Error\n", status: .internalServerError) }
        throw WorkerProtocolError(.unavailable, message: "Reply lost after commit")
      }
      return response
    }
    let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let value: Int = try await ServerTracing.$context.withValue(context) {
      try await OwnerRPC(client: client).call("fixture.effect", true)
    }
    #expect(value == 7)
    #expect(effects.withLock { $0 } == 1)
    let call = try #require(original.withLock { $0 })
    await #expect(throws: WorkerProtocolError.self) { try await client.upload(call, body: .json(.bool(true) as JSONValue)) }
    #expect(effects.withLock { $0 } == 1)
    await bytes.shutdown()
  }

  @Test func lostActivityAcknowledgementResumesTheOriginalPassAdmission() async throws {
    let admissions = Mutex<[UUID]>([])
    let dropped = Mutex(false)
    let bytes = OwnerByteEndpoint(invoke: { call in
      let activity = try ExecutionWorkerActivity(call: call)
      admissions.withLock { $0.append(activity.pass) }
      return try ownerEncode(OwnerEnvelope(value: .bool(true), fault: nil))
    })
    let endpoint = try bytes.endpoint(token: "token", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient { request in
      let response = try await endpoint.handler(request)
      if request.url.path == "/worker/upload", dropped.withLock({ value in defer { value = true }; return !value }) {
        try await response.body.discard()
        throw WorkerProtocolError(.unavailable, message: "Activity acknowledgement lost")
      }
      return response
    }
    let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let pass = UUID()
    try await ExecutionWorkerActivity(session: SessionID("fixture"), pass: pass, active: true).publish(using: client)
    #expect(admissions.withLock { $0 } == [pass])
    #expect(await client.pendingReceipts().isEmpty)
    await bytes.shutdown()
  }

  @Test func knownChildDeathTerminatesReconnectInsteadOfWaitingForAnotherJournal() async throws {
    let bytes = OwnerByteEndpoint(invoke: { _ in .null })
    let endpoint = try bytes.endpoint(token: "token", hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let lost = Mutex(false)
    let fetch = FetchClient { request in
      if lost.withLock({ $0 }) { throw WorkerProtocolError(.unavailable, message: "Known child death") }
      return try await endpoint.handler(request)
    }
    let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let retained = try #require(try await client.retaining(WorkerCall(operation: "fixture.effect", payload: .bool(true))))
    lost.withLock { $0 = true }
    await client.close()
    do {
      let _: Bool = try await OwnerRPC(client: client).retainedCall(retained)
      Issue.record("Closed client admitted an effect")
    } catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
    await #expect(throws: WorkerProtocolError.self) { try await OwnerRPC(client: client).reconnect() }
    await bytes.shutdown()
  }

  @Test func duplicateWaitsForShieldedTaskAndMismatchedPayloadIsRefused() async throws {
    let journal = OwnerReceiptJournal()
    let receipt = WorkerReceipt(endpoint: journal.identity, client: UUID(), sequence: 1)
    let call = WorkerCall(operation: "fixture.effect", payload: .bool(true), receipt: receipt)
    let effects = Mutex(0)
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let first = Task {
      try await journal.run(call) {
        effects.withLock { $0 += 1 }
        signal.yield(())
        for await _ in release {}
        return .integer(9)
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    first.cancel()
    let duplicate = Task { try await journal.run(call) { Issue.record("Duplicate effect admitted"); return .null } }
    await #expect(throws: WorkerProtocolError.self) {
      _ = try await journal.run(WorkerCall(id: call.id, operation: call.operation, payload: .bool(false), receipt: receipt)) { .null }
    }
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    finish.finish()
    #expect(try await duplicate.value.result == .integer(9))
    #expect(effects.withLock { $0 } == 1)
    try await journal.acknowledge(receipt)
    #expect(await journal.inventory().isEmpty)
    await #expect(throws: WorkerProtocolError.self) { _ = try await journal.run(call) { .null } }
    await journal.stop()
  }

  @Test func changedJournalNeverReadmitsUnknownEffect() async throws {
    let effects = Mutex(0)
    let first = OwnerByteEndpoint(invoke: { _ in effects.withLock { $0 += 1 }; return try ownerEncode(OwnerEnvelope(value: .bool(true), fault: nil)) })
    let second = OwnerByteEndpoint(invoke: { _ in effects.withLock { $0 += 1 }; return .null })
    let hello = ExecutionWorkerBootstrap.hello(release: "fixture")
    let before = try first.endpoint(token: "token", hello: hello)
    let after = try second.endpoint(token: "token", hello: hello)
    let changed = Mutex(false)
    let fetch = FetchClient { request in
      if changed.withLock({ $0 }) { return try await after.handler(request) }
      let response = try await before.handler(request)
      if request.url.path == "/worker/upload" {
        changed.withLock { $0 = true }
        throw WorkerProtocolError(.unavailable, message: "Journal lost")
      }
      return response
    }
    let client = try WorkerClient(socket: "/private/owner.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(hello)
    do {
      let _: Bool = try await OwnerRPC(client: client).call("fixture.write", true)
      Issue.record("Unknown committed effect was resubmitted")
    } catch let error as WorkerProtocolError { #expect(error.code == .unknownOutcome) }
    #expect(effects.withLock { $0 } == 1)
    await first.shutdown(); await second.shutdown()
  }

  @Test func handlerReceiptKeepsFiringIdentityAndResultUntilParentConsumption() async throws {
    let invocations = Mutex<[UUID]>([])
    let handler = WorkerHandlerEndpoint(handler: ReceiptHandlerFixture(invoke: { invocation in
      invocations.withLock { $0.append(invocation.id) }
      return .init(stateJSON: "{\"done\":true}", wakes: ["one wake"])
    }))
    let bytes = OwnerByteEndpoint(invoke: handler.invoke)
    let hello = ExecutionWorkerBootstrap.hello(release: "fixture")
    let endpoint = try bytes.endpoint(token: "token", hello: hello)
    let fetch = FetchClient { try await endpoint.handler($0) }
    let client = try WorkerClient(socket: "/private/worker.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(hello)
    let firing = UUID()
    let result = try await RemoteHandlerExecution(client: client).executeHandler(.init(id: firing, path: "/handler.js", session: SessionID("fixture")))
    #expect(result.stateJSON == "{\"done\":true}")
    #expect(result.wakes == ["one wake"])
    let retained = try ownerDecode([WorkerCallInventory].self, await client.call(WorkerCall(operation: "owner.receipts")))
    #expect(retained.count == 1)
    #expect(retained.first?.id == firing)
    #expect(retained.first?.terminal == true)
    #expect(invocations.withLock { $0 } == [firing])
    await result.acknowledge()
    await result.acknowledge()
    #expect(try ownerDecode([WorkerCallInventory].self, await client.call(WorkerCall(operation: "owner.receipts"))).isEmpty)
    #expect(await client.pendingReceipts().isEmpty)
    await bytes.shutdown(); await handler.shutdown()
  }

  @Test func clientAndSequenceBudgetsRefuseBeforeEffectAdmission() async throws {
    let journal = OwnerReceiptJournal()
    let clients = (0 ..< 16).map { _ in UUID() }
    for client in clients { try await journal.acknowledge(.init(endpoint: journal.identity, client: client, sequence: 1)) }
    await #expect(throws: WorkerProtocolError.self) { try await journal.acknowledge(.init(endpoint: journal.identity, client: UUID(), sequence: 1)) }
    await #expect(throws: WorkerProtocolError.self) {
      _ = try await journal.run(WorkerCall(operation: "fixture.effect", receipt: .init(endpoint: journal.identity, client: clients[0], sequence: 1026))) {
        Issue.record("Over-budget effect admitted"); return .null
      }
    }
    #expect(await journal.inventory().isEmpty)
    await journal.stop()
  }

  @Test func outOfOrderAcknowledgementsAndAbandonedAdmissionsStayBounded() async throws {
    let journal = OwnerReceiptJournal()
    let client = UUID()
    let first = WorkerReceipt(endpoint: journal.identity, client: client, sequence: 1)
    let second = WorkerReceipt(endpoint: journal.identity, client: client, sequence: 2)
    try await journal.acknowledge(second)
    await #expect(throws: WorkerProtocolError.self) {
      _ = try await journal.run(WorkerCall(operation: "fixture.effect", receipt: second)) { .null }
    }
    try await journal.acknowledge(first)
    try await journal.acknowledge(second)
    let next = WorkerCall(operation: "fixture.effect", receipt: .init(endpoint: journal.identity, client: client, sequence: 3))
    #expect(try await journal.run(next) { .bool(true) }.result == .bool(true))
    await journal.stop()
  }
}

private struct ReceiptHandlerFixture: HandlerExecutionClient {
  let invoke: @Sendable (ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await invoke(invocation) }
}
