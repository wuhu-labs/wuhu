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
import Fetch
import InferenceKit
import JSONValue
import SessionDomain
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct RuntimeAttemptTransferTests {
  private let session = SessionID("pony-crane-moon")
  private let identity = ParentExecCheckpoint.Identity(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 123, birth: "fixture-process-birth")

  @Test func inheritedAttemptsBecomeVisibleOnlyAtReadinessAndAcceptOriginalTerminalEvent() async throws {
    let space = try Space.inMemory(), sourceHub = AttemptHub(), restoredHub = AttemptHub()
    let owner = InProcessExecutionOwnerClient(space: space)
    let source = ParentExecutionHandoff(owner: owner, runtime: runtime(sourceHub))
    let client = try await client(source)
    let id = UUID()
    try await RemoteExecutionOwner(client: client, tracesAttempts: false).attemptEvents.publish(session: session, .started(attemptID: id))
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) { try await source.requireIdleRuntimeCheckpoint() }
    let checkpoint = try ParentExecCheckpoint.decode(await source.execCheckpoint(identity: identity), expecting: identity)
    #expect(checkpoint.execution.attempts == [.init(id: id, session: session)])
    let carrier = try ParentCheckpointCarrier.export(checkpoint)
    let duplicate = dup(carrier.descriptor)
    _ = try #require(duplicate >= 0)
    let decoded = try ParentCheckpointCarrier.take(duplicate, expecting: identity)
    let restored = try await ParentExecutionHandoff.restoreExec(decoded.execution, owner: owner, runtime: runtime(restoredHub))
    #expect(restoredHub.inFlight(session: session).isEmpty)
    try await restored.commitExec()
    #expect(Set(restoredHub.inFlight(session: session).keys) == [id])
    let replacement = try await self.client(restored)
    let remote = RemoteExecutionOwner(client: replacement, tracesAttempts: false)
    try await remote.attemptEvents.publish(session: session, .delta(attemptID: id, event: .start(AssistantMessage())))
    try await remote.attemptEvents.publish(session: session, .finished(attemptID: id, outcome: .failed(reason: "fixture terminal")))
    #expect(restoredHub.inFlight(session: session).isEmpty)
    await restored.shutdown()
    try await source.resume()
    await source.shutdown()
  }

  @Test(arguments: [false, true]) func inMemoryAndSerializedTransferDoNotPublishSpuriousWorkerLoss(serialized: Bool) async throws {
    let space = try Space.inMemory(), hub = AttemptHub()
    let owner = InProcessExecutionOwnerClient(space: space), id = UUID()
    let source = ParentExecutionHandoff(owner: owner, runtime: runtime(hub))
    let client = try await client(source)
    let events = hub.events(session: session)
    try await RemoteExecutionOwner(client: client, tracesAttempts: false).attemptEvents.publish(session: session, .started(attemptID: id))
    try await source.prepare()
    let restored: ParentExecutionHandoff
    if serialized {
      restored = try await source.restoreSerialized(identity: .init(space: identity.space, generation: identity.generation, incarnation: identity.incarnation, processID: identity.processID, birth: identity.birth), to: owner, runtime: runtime(hub), install: { _ in })
    } else {
      restored = try await source.transfer(to: owner, runtime: runtime(hub))
      try await restored.resume()
    }
    #expect(Set(hub.inFlight(session: session).keys) == [id])
    let replacement = try await self.client(restored)
    try await RemoteExecutionOwner(client: replacement, tracesAttempts: false).attemptEvents.publish(session: session, .finished(attemptID: id, outcome: .failed(reason: "fixture terminal")))
    var iterator = events.makeAsyncIterator()
    guard case .started? = await iterator.next(), case let .finished(terminal, .failed(reason))? = await iterator.next() else { Issue.record("Unexpected attempt publication order"); return }
    #expect(terminal == id && reason == "fixture terminal")
    await restored.shutdown()
  }

  @Test func failedStagedRestoreDoesNotOwnOrTerminateSourceAttempts() async throws {
    let space = try Space.inMemory(), sourceHub = AttemptHub(), stagedHub = AttemptHub()
    let owner = InProcessExecutionOwnerClient(space: space), id = UUID()
    let source = ParentExecutionHandoff(owner: owner, runtime: runtime(sourceHub))
    let client = try await client(source)
    let remote = RemoteExecutionOwner(client: client, tracesAttempts: false)
    try await remote.attemptEvents.publish(session: session, .started(attemptID: id))
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) {
      try await source.restoreSerialized(identity: .init(space: identity.space, generation: identity.generation, incarnation: identity.incarnation, processID: identity.processID, birth: identity.birth), to: owner, runtime: runtime(stagedHub), install: { _ in throw WorkerProtocolError(.unavailable, message: "fixture refusal") })
    }
    #expect(stagedHub.inFlight(session: session).isEmpty)
    #expect(Set(sourceHub.inFlight(session: session).keys) == [id])
    try await remote.attemptEvents.publish(session: session, .finished(attemptID: id, outcome: .failed(reason: "fixture terminal")))
    #expect(sourceHub.inFlight(session: session).isEmpty)
    await source.shutdown()
  }

  @Test func runtimeScriptsStillRefusePreparation() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), runtime: runtime(AttemptHub()))
    let client = try await client(source)
    let rpc = OwnerRPC(client: client)
    let _: Bool = try await rpc.call("runtime.script-started", ScriptActivity(session: session, script: "detached"))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    let _: Bool = try await rpc.call("runtime.script-ended", ScriptActivity(session: session, script: "detached"))
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
  }

  @Test func ownerFenceDrainsThroughReceiptAcknowledgementRatherThanOnlyEffectCompletion() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), runtime: runtime(AttemptHub()))
    let endpoint = try await source.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let entered = AsyncStream<Void>.makeStream(), held = AsyncStream<Void>.makeStream()
    defer { entered.continuation.finish(); held.continuation.finish() }
    let fetch = FetchClient { incoming in
      var request = incoming
      if request.url.path == "/worker/call", let call = try await request.body?.json(WorkerCall.self) {
        request.body = try .json(call)
        if call.operation == "owner.ack" {
          entered.continuation.yield(())
          for await _ in held.stream {}
        }
      }
      return try await endpoint.handler(request)
    }
    let client = try WorkerClient(socket: "/private/fence-ack.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let pending = Task { try await RemoteExecutionOwner(client: client, tracesAttempts: false).scheduleCacheWarming(session, intervalSeconds: 7) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(await client.pendingReceipts().count == 1)
    await #expect(throws: WorkerProtocolError(.handoffTimedOut, message: "Worker owner transaction fence timed out")) {
      try await client.pauseOwnerTransactions(UUID(), drainTimeout: .milliseconds(10), waitTimeout: .seconds(2))
    }
    held.continuation.finish()
    try await pending.value
    let token = UUID()
    try await client.pauseOwnerTransactions(token)
    #expect(await client.pendingReceipts().isEmpty)
    try await source.prepare()
    _ = try await source.exportExec(identity: .init(space: identity.space, generation: identity.generation, incarnation: identity.incarnation, processID: identity.processID, birth: identity.birth))
    try await source.resume()
    try await client.resumeOwnerTransactions(token)
    await source.shutdown()
  }

  @Test func duplicateAttemptsUnknownFieldsAndPrivateMetadataFailClosed() throws {
    let id = UUID(), receipts = OwnerReceiptCheckpoint(identity: UUID(), clients: [])
    let attempt = RuntimeAttempt(id: id, session: session)
    let duplicate = ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: [], attempts: [attempt, attempt]))
    #expect(throws: WorkerProtocolError.self) { try duplicate.encode() }
    let safe = ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: [], attempts: [attempt]))
    let text = String(decoding: try safe.encode(), as: UTF8.self)
    let unknown = text.replacingOccurrences(of: "\"attempts\":[{", with: "\"attempts\":[{\"credential\":\"must-not-be-accepted\",")
    #expect(unknown != text)
    #expect(throws: WorkerProtocolError.self) { try ParentExecCheckpoint.decode(Data(unknown.utf8), expecting: identity) }
    let privateMetadata = ParentExecCheckpoint(identity: identity, execution: .init(receipts: receipts, readers: [], attempts: [.init(id: id, session: .init("Bearer credential-sentinel"))]))
    #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) { try ParentCheckpointCarrier.export(privateMetadata) }
    let privateReceipt = WorkerCall(operation: "inference.provider-credential", payload: .string("credential-sentinel"), receipt: .init(endpoint: receipts.identity, client: UUID(), sequence: 1))
    let unsafe = ParentExecCheckpoint(identity: identity, execution: .init(receipts: .init(identity: receipts.identity, clients: [.init(id: privateReceipt.receipt!.client, consumed: 0, acknowledged: [], entries: [.init(call: privateReceipt, reply: .init(id: privateReceipt.id, result: .string("secret")))])]), readers: [], attempts: [attempt]))
    #expect(throws: ParentCheckpointCarrierError(code: .unprovenCredentialFreedom)) { try ParentCheckpointCarrier.export(unsafe) }
  }

  private func runtime(_ attempts: AttemptHub) -> WorkerRuntimeOwner {
    .init(attempts: attempts, usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
  }

  private func client(_ handoff: ParentExecutionHandoff) async throws -> WorkerClient {
    let endpoint = try await handoff.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/runtime-transfer.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}
