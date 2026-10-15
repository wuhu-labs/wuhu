#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import JSONValue
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ParentHandoffControlTests {
  @Test func retainedActivityAndTelemetryUseBoundControlsButCannotOverrideOwnerEffects() async throws {
    let calls = Mutex<[String]>([])
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), control: { call in
      calls.withLock { $0.append(call.operation) }
      return call.operation == "worker.activity" ? .object(["value": .bool(true), "fault": .null]) : .bool(true)
    })
    let client = try await client(source)
    #expect(try await client.call(.init(operation: "worker.ready", payload: 42)) == .bool(true))
    #expect(try await client.call(.init(operation: "telemetry.spans", payload: .array([]))) == .bool(true))
    let effect = try #require(try await client.retaining(.init(operation: "worker.activity", payload: .null)))
    let input = WorkerCall(id: effect.id, operation: "owner.input", payload: .string(effect.operation), receipt: effect.receipt)
    try await client.upload(input, body: .json(effect.payload))
    let names: [String: String] = try await OwnerRPC(client: client).call("inference.device-names", EmptyRequest())
    #expect(names.isEmpty)
    try await source.prepare()
    await #expect(throws: WorkerProtocolError.self) { try await client.call(.init(operation: "worker.ready")) }
    await #expect(throws: WorkerProtocolError.self) { try await client.stream(.init(operation: "worker.lease")) }
    await #expect(throws: WorkerProtocolError.self) { try await client.reconnect() }
    try await source.resume()
    try await client.reconnect()
    let recovered: Bool = try await OwnerRPC(client: client).retainedCall(effect)
    #expect(recovered)
    #expect(calls.withLock { $0 } == ["worker.ready", "telemetry.spans", "worker.activity"])
    await source.shutdown()
  }

  @Test func leaseEOFIsQuiescenceNotWorkerRetirement() async throws {
    let owner = InProcessExecutionOwnerClient(space: try Space.inMemory())
    let source = ParentExecutionHandoff(owner: owner)
    let client = try await client(source)
    let lease = try await client.stream(.init(operation: "worker.lease"))
    let eof = Task { try await lease.discard() }
    try await source.prepare()
    try await eof.value
    await #expect(throws: WorkerProtocolError.self) { try await client.stream(.init(operation: "worker.lease")) }
    try await source.resume()
    let resumed = try await client.stream(.init(operation: "worker.lease"))
    let resumedEOF = Task { try await resumed.discard() }
    try await source.prepare()
    try await resumedEOF.value
    let replacement = try await source.transfer(to: owner)
    try await replacement.resume()
    let next = try await self.client(replacement)
    let final = try await next.stream(.init(operation: "worker.lease"))
    let finalEOF = Task { try await final.discard() }
    await replacement.shutdown()
    try await finalEOF.value
  }

  @Test func leaseCancellationReleasesBoundedReservations() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    let client = try await client(source)
    for _ in 0 ..< 300 {
      let lease = try await client.stream(.init(operation: "worker.lease"))
      let consume = Task { try await lease.discard() }
      consume.cancel()
      _ = await consume.result
    }
    try await source.prepare()
    await source.shutdown()
  }

  @Test func shutdownCancelsActiveControlsInsteadOfRefusingCleanup() async throws {
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    defer { finish.finish() }
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()), control: { _ in
      signal.yield(())
      for await _ in release {}
      return .bool(true)
    })
    let client = try await client(source)
    let pending = Task { try await client.call(.init(operation: "worker.ready")) }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await source.shutdown()
    await #expect(throws: (any Error).self) { try await pending.value }
    await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    await #expect(throws: WorkerProtocolError.self) { try await client.call(.init(operation: "worker.ready")) }
  }

  @Test func shutdownDuringPreparationCannotReopenAdmissionOnRollback() async throws {
    let source = ParentExecutionHandoff(owner: InProcessExecutionOwnerClient(space: try Space.inMemory()))
    let client = try await client(source)
    let lease = try await client.stream(.init(operation: "worker.lease"))
    let (entered, signal) = AsyncStream<Void>.makeStream()
    let (release, finish) = AsyncStream<Void>.makeStream()
    let reader = Task {
      try await source.bytes.admission.run { ticket in
        try await source.bytes.admission.reader(ticket)
        signal.yield(())
        for await _ in release {}
      }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    let preparing = Task { try await source.prepare() }
    try await lease.discard()
    await source.shutdown()
    finish.finish()
    try await reader.value
    await #expect(throws: WorkerProtocolError.self) { try await preparing.value }
    await #expect(throws: WorkerProtocolError.self) { try await client.reconnect() }
    await #expect(throws: WorkerProtocolError.self) { try await source.resume() }
    await #expect(throws: WorkerProtocolError.self) { try await source.bytes.admission.resume() }
  }

  @Test func transferRequiresExplicitlyReboundControlState() async throws {
    let owner = InProcessExecutionOwnerClient(space: try Space.inMemory())
    let controls = Mutex<[String]>([])
    let source = ParentExecutionHandoff(owner: owner, control: { _ in controls.withLock { $0.append("original") }; return .bool(true) })
    let original = try await client(source)
    _ = try await original.call(.init(operation: "worker.ready"))
    try await source.prepare()
    let restored = try await source.transfer(to: owner, control: { _ in controls.withLock { $0.append("replacement") }; return .bool(false) })
    try await restored.resume()
    let next = try await client(restored)
    #expect(try await next.call(.init(operation: "worker.ready")) == .bool(false))
    #expect(controls.withLock { $0 } == ["original", "replacement"])
    await restored.shutdown()
  }

  @Test(arguments: [false, true]) func shutdownRacingResumeOrTransferCannotResurrectSource(transfer: Bool) async throws {
    for _ in 0 ..< 16 {
      let owner = InProcessExecutionOwnerClient(space: try Space.inMemory())
      let source = ParentExecutionHandoff(owner: owner)
      let original = try await client(source)
      try await source.prepare()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await source.shutdown() }
        group.addTask {
          if transfer {
            if let restored = try? await source.transfer(to: owner) { await restored.shutdown() }
          } else { try? await source.resume() }
        }
      }
      await #expect(throws: WorkerProtocolError.self) { try await original.reconnect() }
      await #expect(throws: WorkerProtocolError.self) { try await source.resume() }
      await #expect(throws: WorkerProtocolError.self) { try await source.prepare() }
    }
  }

  private func client(_ handoff: ParentExecutionHandoff) async throws -> WorkerClient {
    let endpoint = try await handoff.endpoint(credentials: try WorkerCredentials(token: "fixture"), hello: ExecutionWorkerBootstrap.hello(release: "parent"))
    let fetch = FetchClient(fetch: endpoint.handler)
    let client = try WorkerClient(socket: "/private/handoff.sock", token: "fixture", control: fetch, bytes: fetch)
    _ = try await client.negotiate(ExecutionWorkerBootstrap.hello(release: "worker"))
    return client
  }
}
