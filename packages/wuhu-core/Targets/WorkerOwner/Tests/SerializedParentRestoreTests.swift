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

@Suite(.timeLimit(.minutes(2))) struct SerializedParentRestoreTests {
  enum Failure: CaseIterable, Sendable {
    case encoding, encoded, decoded, journal, readers, resumed, installing, identity, corruptBytes, readerOwner, installation, cancellation
    var stage: ParentExecutionHandoff.RestoreStage? {
      switch self {
      case .encoding: .encoding
      case .encoded: .encoded
      case .decoded: .decoded
      case .journal: .journal
      case .readers: .readers
      case .resumed: .resumed
      case .installing: .installing
      default: nil
      }
    }
  }

  private let identity = ParentExecutionIdentity(space: "fixture", generation: UUID(), incarnation: UUID(), processID: 42, birth: "fixture-birth-identity")

  @Test(arguments: Failure.allCases, [false, true]) func everyFailedRestoreResumesSourceWithoutRepeatingEffectsOrReaderReply(failure: Failure, watch: Bool) async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "restore", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let effects = Mutex(0), installed = Mutex(false)
    let runtime = WorkerRuntimeOwner(attempts: AttemptHub(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in effects.withLock { $0 += 1 } })
    let source = ParentExecutionHandoff(owner: InProcessToolOwnerClient(space: space), runtime: runtime)
    let client = try await client(source)
    let rpc = OwnerRPC(client: client)
    let effect = try #require(try await client.retaining(WorkerCall(operation: "runtime.schedule-warming", payload: ownerEncode(WarmingRequest(session: session, intervalSeconds: 7)))))
    try await client.upload(.init(id: effect.id, operation: "owner.input", payload: .string(effect.operation), receipt: effect.receipt), body: .json(effect.payload))
    let reader: UUID = watch
      ? try await rpc.call("script.watch-open", WatchRequest(glob: "**", from: nil, session: session))
      : try await rpc.call("script.observe-open", ObserveRequest(sql: "SELECT path FROM docs", parameters: [], session: session))
    _ = try await space.fs(.shared).write("/first.md", Data("first".utf8), ifMatch: nil)
    let pull = try #require(try await client.retaining(WorkerCall(operation: "script.stream-next", payload: ownerEncode(StreamRequest(id: reader)))))
    try await client.upload(.init(id: pull.id, operation: "owner.input", payload: .string(pull.operation), receipt: pull.receipt), body: .json(pull.payload))
    let output = WorkerCall(id: pull.id, operation: "owner.output", payload: .string(pull.operation), receipt: pull.receipt)
    let before = try await source.bytes.send(output).json(WorkerReply.self)
    try await source.prepare()
    let freshSpace = try Space.inMemory()
    let fresh: any ExecutionOwnerClient = failure == .readerOwner ? InProcessExecutionOwnerClient(space: freshSpace) : InProcessToolOwnerClient(space: freshSpace)
    let identity = failure == .identity ? ParentExecutionIdentity(space: "", generation: UUID(), incarnation: UUID(), processID: 0, birth: "") : identity
    let result = Task {
      try await source.restoreSerialized(identity: identity, to: fresh, runtime: runtime, transform: { bytes in
        failure == .corruptBytes ? Data("{}".utf8) : bytes
      }, stage: { stage in
        if failure.stage == stage { throw WorkerProtocolError(.unavailable, message: "Injected restore failure") }
        if failure == .cancellation, stage == .resumed {
          withUnsafeCurrentTask { $0?.cancel() }
          try Task.checkCancellation()
        }
      }, install: { _ in
        if failure == .installation { throw WorkerProtocolError(.unavailable, message: "Installation refused") }
        installed.withLock { $0 = true }
      })
    }
    await #expect(throws: (any Error).self) { try await result.value }
    #expect(!installed.withLock { $0 })
    _ = try await source.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let recovered: Bool = try await rpc.retainedCall(effect)
    #expect(recovered)
    #expect(effects.withLock { $0 } == 1)
    #expect(try await source.bytes.send(output).json(WorkerReply.self) == before)
    _ = try await client.call(.init(operation: "owner.ack", payload: ownerEncode(pull.receipt!)))
    _ = try await space.fs(.shared).write("/second.md", Data("second".utf8), ifMatch: nil)
    let next: OwnerRecord = try await rpc.call("script.stream-next", StreamRequest(id: reader))
    #expect(next.value != nil && !next.ended)
    let originalRecord = try ownerDecode(OwnerRecord.self, ownerDecode(OwnerEnvelope.self, before.result!).value)
    #expect(next.value != originalRecord.value)
    let _: Bool = try await rpc.call("runtime.schedule-warming", WarmingRequest(session: session, intervalSeconds: 8))
    #expect(effects.withLock { $0 } == 2)
    try await source.prepare()
    try await source.resume()
    await source.shutdown()
  }

  @Test(arguments: [false, true]) func shutdownWhileInstallingDoesNotResurrectEitherOwner(installationFails: Bool) async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    try await source.prepare()
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let staged = Mutex<ParentExecutionHandoff?>(nil)
    let pending = Task {
      try await source.restoreSerialized(identity: identity, to: InProcessExecutionOwnerClient(space: try Space.inMemory()), install: { replacement in
        staged.withLock { $0 = replacement }
        signal.yield(())
        for await _ in release {}
        if installationFails { throw WorkerProtocolError(.unavailable, message: "Publication stopped") }
      })
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await source.shutdown()
    finish.finish()
    if installationFails {
      await #expect(throws: WorkerProtocolError.self) { try await pending.value }
    } else {
      _ = try await pending.value
    }
    await #expect(throws: WorkerProtocolError.self) { try await source.resume() }
    let replacement = try #require(staged.withLock { $0 })
    await #expect(throws: WorkerProtocolError.self) { try await replacement.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent")) }
  }

  private func client(_ source: ParentExecutionHandoff) async throws -> WorkerClient {
    let endpoint = try await source.endpoint(credentials: WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/restore.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}
