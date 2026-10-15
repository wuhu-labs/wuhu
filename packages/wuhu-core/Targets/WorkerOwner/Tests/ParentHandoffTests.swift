#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import SessionDomain
import SessionTools
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ParentHandoffTests {
  @Test func lostReplyAndConsumedFenceTransferWithoutReplayingRecordedEffect() async throws {
    let space = try Space.inMemory()
    let owner = InProcessToolOwnerClient(space: space)
    let effects = Mutex<[Int]>([])
    let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { session, interval in
      #expect(session == SessionID("fixture"))
      effects.withLock { $0.append(interval) }
    })
    let source = ParentExecutionHandoff(owner: owner, runtime: runtime)
    let endpoint = try await source.endpoint(credentials: try WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let current = Mutex(endpoint)
    let fetch = FetchClient { request in try await current.withLock { $0 }.handler(request) }
    let client = try WorkerClient(socket: "/private/handoff.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    let effect = try #require(try await client.retaining(WorkerCall(operation: "runtime.schedule-warming", payload: ownerEncode(WarmingRequest(session: .init("fixture"), intervalSeconds: 7)))))
    let input = WorkerCall(id: effect.id, operation: "owner.input", payload: .string(effect.operation), receipt: effect.receipt)
    try await client.upload(input, body: .json(effect.payload))
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    let restored = try await source.transfer(to: owner, runtime: runtime)
    await #expect(throws: WorkerProtocolError.self) { try await source.resume() }
    await #expect(throws: WorkerProtocolError.self) { try await source.transfer(to: owner) }
    await #expect(throws: WorkerProtocolError.self) { try await restored.bytes.receive(input, body: .json(effect.payload)) }
    try await restored.resume()
    let replacement = try await restored.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    current.withLock { $0 = replacement }
    try await client.reconnect()
    let recovered: Bool = try await OwnerRPC(client: client).retainedCall(effect)
    #expect(recovered)
    #expect(effects.withLock { $0 } == [7])
    try await restored.prepare()
    let final = try await restored.transfer(to: owner, runtime: runtime)
    try await final.resume()
    await #expect(throws: WorkerProtocolError.self) { try await final.bytes.receive(input, body: .json(effect.payload)) }
    #expect(effects.withLock { $0 } == [7])
    await final.shutdown()
  }

  @Test(arguments: [false, true], [false, true]) func stagedLogicalReaderReplyTransfersWithItsAcknowledgement(watch: Bool, serialized: Bool) async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "reader", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let owner = InProcessToolOwnerClient(space: space)
    let source = ParentExecutionHandoff(owner: owner)
    let client = try await client(source)
    let rpc = OwnerRPC(client: client)
    let id: UUID = watch
      ? try await rpc.call("script.watch-open", WatchRequest(glob: "**", from: nil, session: session))
      : try await rpc.call("script.observe-open", ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: session))
    _ = try await space.fs(.shared).write("/first.md", Data("first".utf8), ifMatch: nil)
    let pull = try #require(try await client.retaining(WorkerCall(operation: "script.stream-next", payload: ownerEncode(StreamRequest(id: id)))))
    let input = WorkerCall(id: pull.id, operation: "owner.input", payload: .string(pull.operation), receipt: pull.receipt)
    try await client.upload(input, body: .json(pull.payload))
    let output = WorkerCall(id: pull.id, operation: "owner.output", payload: .string(pull.operation), receipt: pull.receipt)
    let original = try await source.bytes.send(output).json(WorkerReply.self)
    try await source.prepare()
    let restored: ParentExecutionHandoff
    if serialized {
      restored = try await source.restoreSerialized(identity: .init(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 42, birth: "fixture-birth-identity"), to: owner, install: { _ in })
    } else {
      restored = try await source.transfer(to: owner)
      try await restored.resume()
    }
    let replay = try await restored.bytes.send(output).json(WorkerReply.self)
    #expect(replay == original)
    let destination = try await self.client(restored)
    _ = try await destination.call(WorkerCall(operation: "owner.ack", payload: ownerEncode(pull.receipt!)))
    _ = try await space.fs(.shared).write("/second.md", Data("second".utf8), ifMatch: nil)
    let next: OwnerRecord = try await OwnerRPC(client: destination).call("script.stream-next", StreamRequest(id: id))
    #expect(next.value != nil)
    #expect(!next.ended)
    try await restored.prepare()
    try await restored.resume()
    await restored.shutdown()
  }

  @Test func unfinishedShieldedEffectRefusesPreparationWithoutCancellingOrStrandingAdmission() async throws {
    let space = try Space.inMemory()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let effects = Mutex(0)
    let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in
      effects.withLock { $0 += 1 }
      signal.yield(())
      for await _ in release {}
    })
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime)
    let client = try await client(source)
    let call = try #require(try await client.retaining(WorkerCall(operation: "runtime.schedule-warming", payload: ownerEncode(WarmingRequest(session: .init("fixture"), intervalSeconds: 3)))))
    let input = WorkerCall(id: call.id, operation: "owner.input", payload: .string(call.operation), receipt: call.receipt)
    let pending = Task { try await source.bytes.receive(input, body: .json(call.payload)) }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    pending.cancel()
    _ = await pending.result
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    finish.finish()
    try await source.bytes.receive(input, body: .json(call.payload))
    #expect(effects.withLock { $0 } == 1)
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
  }

  @Test func legacyByteReplyRefusesUntilConsumed() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    let input = WorkerCall(operation: "owner.input", payload: .string("inference.device-names"))
    try await source.bytes.receive(input, body: .json(.null as JSONValue))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    _ = try await source.bytes.send(WorkerCall(id: input.id, operation: "owner.output", payload: input.payload))
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
  }

  @Test func failedReaderRebindingKeepsTheOriginalPausedAndResumable() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "reader", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let source = ParentExecutionHandoff(owner: InProcessToolOwnerClient(space: space))
    let client = try await client(source)
    let _: UUID = try await OwnerRPC(client: client).call("script.observe-open", ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: session))
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) { try await source.transfer(to: InProcessExecutionOwnerClient(space: space)) }
    try await source.resume()
    let names: [String: String] = try await OwnerRPC(client: client).call("inference.device-names", EmptyRequest())
    #expect(names.isEmpty)
    await source.shutdown()
  }

  @Test func activeRuntimeStateAndCancellationFencesAreNotSilentlyDropped() async throws {
    let space = try Space.inMemory()
    let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime)
    let client = try await client(source)
    let rpc = OwnerRPC(client: client)
    let activity = ScriptActivity(session: .init("fixture"), script: "active")
    let _: Bool = try await rpc.call("runtime.script-started", activity)
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    let _: Bool = try await rpc.call("runtime.script-ended", activity)
    try await source.prepare()
    try await source.resume()
    _ = try await client.call(WorkerCall(operation: "owner.cancel", payload: ownerEncode(StreamRequest(id: UUID()))))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    await source.shutdown()
  }

  @Test func identityReplyAndLegacyReaderResourcesRefuseHandoff() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "resources", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let owner = InProcessToolOwnerClient(space: space, identityFetch: { _, _, protect in protect("private-fixture"); return .text("reply") })
    let source = ParentExecutionHandoff(owner: owner)
    let identity = try WorkerCall(operation: "script.identity-upload", payload: ownerEncode(IdentityRequestSnapshot(Request(url: URL(string: "https://fixture.invalid/")!), session: session)))
    try await source.bytes.receive(identity, body: .string(""))
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    let metadata = try WorkerCall(operation: "script.identity-response", payload: ownerEncode(StreamRequest(id: identity.id)))
    _ = try await source.bytes.send(metadata)
    let body = try await source.bytes.send(WorkerCall(operation: "script.identity-body", payload: ownerEncode(StreamRequest(id: identity.id))))
    try await body.discard()
    try await source.prepare()
    try await source.resume()
    let definition = try WorkerCall(operation: "script.observe-open", payload: ownerEncode(ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: session)))
    _ = try await source.bytes.send(definition)
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    await source.shutdown()
  }

  @Test func cancelledPreparationRollsBackAndMismatchedStagedReceiptIsRejected() async throws {
    let space = try Space.inMemory()
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: space))
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await source.prepare()
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
    let identity = UUID(), client = UUID(), readerID = UUID(), stagedID = UUID()
    let definition = try WorkerCall(id: readerID, operation: "script.observe-open", payload: ownerEncode(ObserveRequest(sql: "SELECT 1", parameters: [], session: .init("fixture"))), receipt: .init(endpoint: identity, client: client, sequence: 1))
    let reader = ScriptStreamCheckpoint(definition: definition, reader: .init(cursor: .init(), stagedID: stagedID, stagedValue: .string("private-fixture"), ended: false, overflowed: false))
    let checkpoint = ParentExecutionCheckpoint(receipts: .init(identity: identity, clients: []), readers: [reader])
    #expect(throws: WorkerProtocolError.self) { try checkpoint.validate() }
    #expect(!String(reflecting: checkpoint).contains("private-fixture"))
    #expect(Mirror(reflecting: checkpoint).children.isEmpty)
  }

  private func client(_ handoff: ParentExecutionHandoff) async throws -> WorkerClient {
    let endpoint = try await handoff.endpoint(credentials: try WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/handoff.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}
