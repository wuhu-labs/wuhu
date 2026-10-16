import ServerTelemetry
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Clocks
import Fetch
import enum JSONValue.JSONValue
@testable import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Synchronization
import Testing

private final class LocalTime: Sendable {
  let value = Mutex<Duration>(.zero)
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { _ in throw CancellationError() }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

private final class Pause: Sendable {
  let entered: AsyncStream<Void>
  let enteredWriter: AsyncStream<Void>.Continuation
  let released: AsyncStream<Void>
  let releaseWriter: AsyncStream<Void>.Continuation
  init() {
    (entered, enteredWriter) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
    (released, releaseWriter) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }

  func wait() async { enteredWriter.yield(()); enteredWriter.finish(); for await _ in released {} }
  func arrival() async { for await _ in entered {} }
  func release() { releaseWriter.finish() }
}

private actor PausedReadStore: OperationStore {
  let base = MemoryOperationStore()
  var nextRead: Pause?
  func pause(_ gate: Pause) { nextRead = gate }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord {
    let record = try await base.read(id)
    if let gate = nextRead { nextRead = nil; await gate.wait() }
    return record
  }

  func transaction(_ id: UUID, _ update: @escaping @Sendable (inout ClientRecord) throws -> Void) async throws -> ClientRecord {
    try await base.transaction(id, update)
  }
}

private struct QueryKind: OperationKind {
  struct Input: Codable, Sendable { let large: Bool }
  let descriptor = KindDescriptor(
    "query.v1",
    inputSchema: [:],
    resultSchema: [:],
    inputChannels: [.init("in", windowBytes: 65536)],
    outputChannels: [.init("out", windowBytes: 65536)],
  )
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    if input.large { try await channels.send(.init(data: Data(repeating: 42, count: 65536)), to: "out") }
    return input.large ? .string(String(repeating: "x", count: 65534)) : "done"
  }
}

private func driver(
  _ agent: OperationAgent,
  time: LocalTime,
  store: any OperationStore,
  fetch: FetchClient? = nil,
) throws -> OperationClient {
  try .init(
    origin: URL(string: "https://memory.invalid")!,
    fetch: fetch ?? .init(fetch: agent.handler),
    clock: time.clock,
    store: store,
    abort: { _ in },
    trace: { _ in },
  )
}

private func machine(_ time: LocalTime) throws -> OperationAgent {
  try .init(machine: "phone", kinds: [.init(QueryKind())], clock: time.clock, authorize: { _, _ in })
}

private func start(_ driver: OperationClient, key: String = "one", large: Bool = false) async throws -> UUID {
  try await driver.start("phone", request: .init(kind: "query.v1", input: ["large": .bool(large)]), owner: .init(scope: "test", key: key))
}

private func expectCode(_ code: OperationError.Code, _ work: () async throws -> Void) async {
  do { try await work(); Issue.record("Expected \(code)") }
  catch let error as OperationError { #expect(error.code == code) }
  catch { Issue.record("Unexpected \(error)") }
}

@Suite struct ClientReviewRegressionTests {
  @Test func exclusionPrecedesSuspendedCursorRead() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = PausedReadStore()
    let client = try driver(agent, time: time, store: store)
    _ = try await client.describe("phone"); let id = try await start(client)
    let gate = Pause(); await store.pause(gate)
    let a = Task { try await client.write(id, channel: "in", payload: .init(data: Data([65]))) }
    await gate.arrival()
    await expectCode(.capacityExceeded) { _ = try await client.write(id, channel: "in", payload: .init(data: Data([66]))) }
    if await agent.operations[id]?.inputs["in"]?.through != .zero { _ = try await agent.read("in", bytes: 1, id: id) }
    gate.release(); _ = try await a.value
    #expect(try await agent.read("in", bytes: 1, id: id)?.data == Data([65]))
    await client.shutdown()
  }

  @Test func maximumTerminalResultAndOutputShareOneBoundedEnvelope() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let client = try driver(agent, time: time, store: store)
    _ = try await client.describe("phone"); let id = try await start(client, large: true)
    await agent.execute(id)
    let snapshot = try await client.poll(id, channel: "out")
    #expect(snapshot.verdict?.tag == .completed)
    #expect(snapshot.payload?.data?.count == 65536)
    #expect(try await store.read(id).committed["out"] == Offset(rawValue: 65536))
    await client.shutdown()
  }

  @Test func abandonedOperationStillBecomesUnknownAfterFullSilenceLease() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let offline = Mutex(false)
    let fetch = FetchClient { request in
      if offline.withLock({ $0 }) { throw OperationError(.transport) }
      return try await agent.handler(request)
    }
    let client = try driver(agent, time: time, store: store, fetch: fetch)
    _ = try await client.describe("phone"); let id = try await start(client)
    offline.withLock { $0 = true }
    await expectCode(.transport) { _ = try await client.stop(id, reason: "callerCancelled") }
    time.advance(.seconds(59))
    await expectCode(.transport) { _ = try await client.reconcile(id) }
    #expect(try await store.read(id).unknown == nil)
    time.advance(.seconds(1))
    await expectCode(.unknownOperation) { _ = try await client.reconcile(id) }
    #expect(try await store.read(id).unknown?.details == ["outcome": "unknown", "reason": "leaseSilence"])
    await client.shutdown()
  }

  @Test func definitiveUnknownFromStopIsPersisted() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let fetch = FetchClient { request in
      if request.url.path.hasSuffix("/stop") {
        let response = try await agent.handler(request)
        return try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound, headers: response.headers)
      }
      return try await agent.handler(request)
    }
    let client = try driver(agent, time: time, store: store, fetch: fetch)
    _ = try await client.describe("phone"); let id = try await start(client)
    await expectCode(.unknownOperation) { _ = try await client.stop(id, reason: "callerCancelled") }
    #expect(try await store.read(id).unknown?.code == .unknownOperation)
    #expect(try await store.read(id).unknown?.details == nil)
    await client.shutdown()
  }

  @Test func completedPostClearsPrematureUnknownFromConcurrentOwnerQuery() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore(); let gate = Pause()
    let fetch = FetchClient { request in
      if request.method == .post { await gate.wait() }
      return try await agent.handler(request)
    }
    let client = try driver(agent, time: time, store: store, fetch: fetch)
    _ = try await client.describe("phone")
    let a = Task { try await start(client) }; await gate.arrival()
    await expectCode(.unknownOperation) { _ = try await start(client) }
    gate.release(); let id = try await a.value
    #expect(try await store.read(id).unknown == nil)
    _ = try await client.poll(id)
    await client.shutdown()
  }

  @Test func idleMachineIsProbedRatherThanDeclaredLostFromStaleCache() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let client = try driver(agent, time: time, store: store)
    _ = try await client.describe("phone"); time.advance(.seconds(61))
    _ = try await start(client)
    await client.shutdown()
  }

  @Test func olderRunningSnapshotCannotReplaceTerminalEvidence() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let client = try driver(agent, time: time, store: store)
    _ = try await client.describe("phone"); let id = try await start(client)
    let record = try await store.read(id)
    await agent.execute(id); _ = try await client.poll(id)
    let running = OperationSnapshot(operation: id, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)
    _ = try await client.commit(running, record: record)
    #expect(try await store.read(id).snapshot?.verdict?.tag == .completed)
    await client.shutdown()
  }

  @Test func channelAnswerFromBeforeTheVerdictStillDeliversItsBytes() async throws {
    let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
    let client = try driver(agent, time: time, store: store)
    _ = try await client.describe("phone"); let id = try await start(client, large: true)
    let record = try await store.read(id)
    await agent.execute(id); _ = try await client.poll(id)
    let head = ChannelPayload(data: Data(repeating: 42, count: 3))
    func answer(from: UInt64) -> OperationSnapshot {
      .init(
        operation: id,
        verdict: nil,
        terminalToken: nil,
        finalOffsets: [:],
        outputConsumed: false,
        channel: "out",
        from: Offset(rawValue: from),
        through: Offset(rawValue: from + 3),
        payload: head,
      )
    }
    _ = try await client.commit(answer(from: 0), record: record)
    _ = try await client.commit(answer(from: 0), record: record)
    #expect(try await store.read(id).snapshot?.verdict?.tag == .completed)
    #expect(try await client.takeOutput(id, channel: "out") == [head])
    let rest = try await client.poll(id, channel: "out")
    #expect(rest.from == Offset(rawValue: 3))
    #expect(rest.payload?.data == Data(repeating: 42, count: 65533))
    await client.shutdown()
  }
}

@Test func stoppedRequestDeadlineIsClampedToRemainingSilenceLease() async throws {
  let clock = TestClock<Duration>()
  let origin = clock.now
  let sleeping = Mutex(0)
  let time = OperationClock(now: { origin.duration(to: clock.now) }, sleep: { duration in
    sleeping.withLock { $0 += 1 }; try await clock.sleep(for: duration)
  })
  let agent = try OperationAgent(machine: "phone", kinds: [.init(QueryKind())], clock: time, authorize: { _, _ in })
  let gate = Pause()
  let fetch = FetchClient { request in
    if request.url.path.hasSuffix("/stop") { await gate.wait() }
    return try await agent.handler(request)
  }
  let store = MemoryOperationStore()
  let client = try OperationClient(
    origin: URL(string: "https://memory.invalid")!,
    fetch: fetch,
    clock: time,
    store: store,
    abort: { _ in },
    trace: { _ in },
  )
  _ = try await client.describe("phone"); let id = try await start(client)
  await clock.advance(by: .seconds(59))
  let outcome = Mutex<OperationError.Code?>(nil)
  sleeping.withLock { $0 = 0 }
  let call = Task {
    do { _ = try await client.stop(id, reason: "callerCancelled"); outcome.withLock { $0 = .invalidResponse } }
    catch let error as OperationError { outcome.withLock { $0 = error.code } }
    catch { outcome.withLock { $0 = .transport } }
  }
  await gate.arrival()
  for _ in 0 ..< 2000 { if sleeping.withLock({ $0 > 0 }) { break }; await Task.yield() }
  await clock.advance(by: .seconds(1))
  for _ in 0 ..< 2000 { if outcome.withLock({ $0 != nil }) { break }; await Task.yield() }
  #expect(outcome.withLock { $0 } == .unknownOperation)
  #expect(try await store.read(id).unknown?.details == ["outcome": "unknown", "reason": "leaseSilence"])
  gate.release(); call.cancel(); await call.value
  await client.shutdown()
}

@Test func callerCancellationHasDistinctTypedTrace() async throws {
  let time = LocalTime(); let agent = try machine(time); let gate = Pause()
  let traces = Mutex<[OperationTrace]>([])
  let client = try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: .init { request in
    await gate.wait(); return try await agent.handler(request)
  }, clock: time.clock, store: MemoryOperationStore(), abort: { _ in }, trace: { event in traces.withLock { $0.append(event) } })
  let outcome = Mutex<OperationError.Code?>(nil)
  let call = Task {
    do { _ = try await client.describe("phone"); outcome.withLock { $0 = .invalidResponse } }
    catch let error as OperationError { outcome.withLock { $0 = error.code } }
    catch { outcome.withLock { $0 = .transport } }
  }
  await gate.arrival(); call.cancel()
  for _ in 0 ..< 2000 {
    if outcome.withLock({ $0 != nil }) && traces.withLock({ $0.contains { $0.event.rawValue == "cancelled" } }) { break }
    await Task.yield()
  }
  #expect(outcome.withLock { $0?.rawValue } == "requestCancelled")
  #expect(traces.withLock { $0.map(\.event.rawValue) } == ["dispatch", "cancelled"])
  #expect(traces.withLock { $0.last?.error?.rawValue } == "requestCancelled")
  gate.release(); await call.value; await client.shutdown()
}

private struct SlashKind: OperationKind {
  struct Input: Codable, Sendable {}
  let descriptor = KindDescriptor("slashes.v1", inputSchema: [:], resultSchema: [:], outputChannels: [.init("out")])
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    try await channels.send(.init(data: Data(repeating: 255, count: 65536)), to: "out")
    return .string(String(repeating: "/", count: 65534))
  }
}

@Test func slashHeavyMaximumTerminalEnvelopeFitsWireBudget() async throws {
  let time = LocalTime()
  let agent = try OperationAgent(machine: "phone", kinds: [.init(SlashKind())], clock: time.clock, authorize: { _, _ in })
  let store = MemoryOperationStore()
  let client = try driver(agent, time: time, store: store)
  _ = try await client.describe("phone")
  let id = try await client.start("phone", request: .init(kind: "slashes.v1", input: [:]), owner: .init(scope: "test", key: "slashes"))
  await agent.execute(id)
  let snapshot = try await client.poll(id, channel: "out")
  #expect(snapshot.payload?.data == Data(repeating: 255, count: 65536))
  #expect(snapshot.verdict?.result == .string(String(repeating: "/", count: 65534)))
  #expect(try await store.read(id).committed["out"] == Offset(rawValue: 65536))
  await client.shutdown()
}

@Test func delayedUnknownFromBeforeStartCannotOverwriteNewRunningEvidence() async throws {
  let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore()
  let post = Pause(); let unknown = Pause()
  let fetch = FetchClient { request in
    if request.method == .post { await post.wait() }
    let response = try await agent.handler(request)
    if request.method == .get && response.status.code == 404 { await unknown.wait() }
    return response
  }
  let client = try driver(agent, time: time, store: store, fetch: fetch)
  _ = try await client.describe("phone")
  let a = Task { try await start(client) }; await post.arrival()
  let b = Task { await expectCode(.unknownOperation) { _ = try await start(client) } }
  await unknown.arrival()
  post.release(); let id = try await a.value
  #expect(try await store.read(id).snapshot != nil)
  unknown.release(); await b.value
  #expect(try await store.read(id).unknown == nil)
  _ = try await client.poll(id)
  await client.shutdown()
}

@Test func delayedUnknownIsFencedAgainstAConcurrentInputReceipt() async throws {
  let time = LocalTime(); let agent = try machine(time); let store = MemoryOperationStore(); let unknown = Pause()
  let fetch = FetchClient { request in
    let response = try await agent.handler(request)
    if request.method == .get && request.url.path.contains("/operations/") {
      let missing = try Response.json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound, headers: response.headers)
      await unknown.wait(); return missing
    }
    return response
  }
  let client = try driver(agent, time: time, store: store, fetch: fetch)
  _ = try await client.describe("phone"); let id = try await start(client)
  let old = Task { await expectCode(.unknownOperation) { _ = try await client.poll(id) } }
  await unknown.arrival()
  _ = try await client.write(id, channel: "in", payload: .init(data: Data([1])))
  unknown.release(); await old.value
  #expect(try await store.read(id).unknown == nil)
  await client.shutdown()
}

@Test func machineOperationSpanUsesStartingContextAndResolvedMachine() async throws {
  let spans = Mutex<[FinishedSpan]>([])
  try await ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
    let time = LocalTime()
    let agent = try machine(time)
    let client = try driver(agent, time: time, store: MemoryOperationStore())
    _ = try await client.describe("phone")
    let tool = ServerSpan(.tool, session: "session", group: "shared")
    let id = try await ServerTracing.$context.withValue(tool.context) { try await start(client) }
    await agent.execute(id)
    let snapshot = try await client.reconcile(id)
    #expect(snapshot.verdict != nil)
    let operation = try #require(spans.withLock { $0.first { $0.name == .machine } })
    #expect(operation.parentSpanID == tool.context?.spanID)
    #expect(operation.context.session == "session")
    #expect(operation.attributes[.machine] == "phone")
    #expect(operation.attributes[.version] == "v2")
    #expect(operation.attributes[.kind] == "query.v1")
    #expect(operation.attributes[.verdict] == "completed")
    #expect(!String(decoding: try JSONEncoder().encode(operation), as: UTF8.self).contains("done"))
    await client.shutdown()
  }
}

@Test func oldServerStartForGatedLinkedKindSurfacesTheTypedRefusal() async throws {
  // The server's view is an old build's: describe without availability, so its precheck admits the linked kind and dispatches.
  let time = LocalTime()
  let agent = try OperationAgent(machine: "phone", kinds: [.init(QueryKind())], clock: time.clock, availability: .init { ["query.v1": .needsConsent] }, authorize: { _, _ in })
  let fetch = FetchClient { request in
    var response = try await agent.handler(request)
    if request.method == .get, request.url.path.hasSuffix("/machines/phone") {
      let d = try await response.body.json(MachineDescription.self)
      response.body = try .json(MachineDescription(instance: d.instance, acceptingStarts: d.acceptingStarts, limits: d.limits, kinds: d.kinds))
    }
    return response
  }
  let client = try driver(agent, time: time, store: MemoryOperationStore(), fetch: fetch)
  #expect(try await client.describe("phone").availability == nil)
  do {
    _ = try await start(client)
    Issue.record("a gated start must be refused")
  } catch let error as OperationError {
    #expect(error.code == .kindUnavailable)
    #expect(error.details == ["kind": "query.v1", "reason": "needsConsent"])
  }
  #expect(await agent.operations.isEmpty)
  await client.shutdown()
}

@Test func unknownErrorCodeFromANewerMachineDecodesAsItself() async throws {
  let time = LocalTime(); let agent = try machine(time)
  let fetch = FetchClient { request in
    guard request.method == .post else { return try await agent.handler(request) }
    var response = try Response.json(["error": ["code": "quotaPaused", "message": "later"]] as JSONValue, status: .init(code: 409))
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
    return response
  }
  let client = try driver(agent, time: time, store: MemoryOperationStore(), fetch: fetch)
  _ = try await client.describe("phone")
  do {
    _ = try await start(client)
    Issue.record("the refusal must surface")
  } catch let error as OperationError {
    #expect(error.code.rawValue == "quotaPaused")
    #expect(!error.code.isKnown)
    #expect(error.message == "later")
  }
  await client.shutdown()
}

extension ClientReviewRegressionTests {
  @Test(arguments: ["poll", "consume", "write"])
  func concurrentOperationRefusalsHaveReasonsAndAreTraced(action: String) async throws {
    let time = LocalTime(); let agent = try machine(time); let store = PausedReadStore()
    let traces = Mutex<[OperationTrace]>([])
    let client = try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: .init(fetch: agent.handler), clock: time.clock, store: store, abort: { _ in }, trace: { trace in traces.withLock { $0.append(trace) } })
    _ = try await client.describe("phone"); let id = try await start(client)
    let gate = Pause(); await store.pause(gate)
    let first = Task { try await Self.perform(action, client: client, id: id) }
    await gate.arrival()
    do {
      try await Self.perform(action, client: client, id: id)
      Issue.record("Concurrent operation was admitted")
    } catch let error as OperationError {
      #expect(error.code == .capacityExceeded)
      #expect(error.operation == id)
      #expect(error.message.contains("already busy"))
      #expect(error.details?.object?["reason"]?.stringValue?.hasPrefix("concurrent") == true)
    }
    #expect(traces.withLock { $0.filter { $0.event == .failure && $0.error == .capacityExceeded }.count } == 1)
    gate.release(); try await first.value
    await client.shutdown()
  }

  private static func perform(_ action: String, client: OperationClient, id: UUID) async throws {
    switch action {
    case "poll": _ = try await client.poll(id, channel: "out")
    case "consume": _ = try await client.takeOutput(id, channel: "out")
    default: _ = try await client.write(id, channel: "in", payload: .init(data: Data([65])))
    }
  }

  @Test func skippedPresenceIsSilentAndGetsTheNextFreeSlotBeforeRecovery() async throws {
    let firstGate = Pause(); let secondGate = Pause(); let traces = Mutex<[OperationTrace]>([])
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
    let client = try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: .init { request in
      if request.url.path.hasSuffix("/first") { await firstGate.wait() }
      if request.url.path.hasSuffix("/second") { await secondGate.wait() }
      var response = try Response.json(description)
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID"] { response.headers[.init(name)!] = request.headers[name] }
      response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
      return response
    }, store: MemoryOperationStore(), maxExchanges: 2, abort: { _ in }, trace: { trace in traces.withLock { $0.append(trace) } })
    let first = Task { try await client.describe("first") }
    let second = Task { try await client.describe("second") }
    await firstGate.arrival(); await secondGate.arrival()
    for _ in 0 ..< 4 { #expect(try await client.probe("healthy") == nil) }
    #expect(traces.withLock { $0.filter { $0.event == .failure }.isEmpty })
    firstGate.release(); _ = try await first.value
    await expectCode(.capacityExceeded) { _ = try await client.describe("recovery") }
    #expect(try await client.probe("healthy")?.acceptingStarts == true)
    #expect(traces.withLock { $0.filter { $0.path.hasSuffix("/healthy") && $0.event == .dispatch }.count } == 1)
    #expect(traces.withLock { $0.filter { $0.path.hasSuffix("/healthy") && $0.event == .failure }.isEmpty })
    secondGate.release(); _ = try await second.value
    await client.shutdown()
  }

  @Test func removedProbeReservationExpiresWithoutAnotherProbe() async throws {
    let time = LocalTime(); let gate = Pause(); let calls = Mutex(0)
    let ledger = ExchangeLedger(fetch: .init { request in
      calls.withLock { $0 += 1 }; await gate.wait()
      var response = Response.text("ok")
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID"] { response.headers[.init(name)!] = request.headers[name] }
      response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
      return response
    }, clock: time.clock, capacity: 1, abort: { _ in }, trace: { _ in })
    var request = Request(url: URL(string: "https://memory.invalid/machine/v2/machines/recovery")!)
    request.headers["X-Wuhu-Correlation-ID"] = UUID().uuidString
    request.headers["X-Wuhu-Request-ID"] = UUID().uuidString
    let recoveryRequest = request
    let first = Task { try await ledger.exchange(recoveryRequest, id: UUID(), timeout: .seconds(30), limit: 1024) }
    await gate.arrival()
    let removedProbe = Request(url: URL(string: "https://memory.invalid/machine/v2/machines/removed")!)
    await #expect(throws: ExchangeSkipped.self) {
      try await ledger.exchange(removedProbe, id: UUID(), timeout: .seconds(1), limit: 1024, opportunistic: true)
    }
    gate.release(); _ = try await first.value
    time.advance(.seconds(4))
    await expectCode(.capacityExceeded) { _ = try await ledger.exchange(recoveryRequest, id: UUID(), timeout: .seconds(30), limit: 1024) }
    #expect(calls.withLock { $0 } == 1)
    time.advance(.seconds(1))
    _ = try await ledger.exchange(recoveryRequest, id: UUID(), timeout: .seconds(30), limit: 1024)
    #expect(calls.withLock { $0 } == 2)
    await ledger.shutdown()
  }

  @Test func hangingPresenceHasOneSecondDeadlineAndHealthyProbesProgress() async throws {
    let clock = TestClock<Duration>(); let origin = clock.now; let sleeps = Mutex(0)
    let time = OperationClock(now: { origin.duration(to: clock.now) }, sleep: { duration in
      sleeps.withLock { $0 += 1 }; try await clock.sleep(for: duration)
    })
    let gate = Pause(); let traces = Mutex<[OperationTrace]>([])
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
    let client = try OperationClient(origin: URL(string: "https://memory.invalid")!, fetch: .init { request in
      if request.url.path.hasSuffix("/hanging") { await gate.wait() }
      var response = try Response.json(description)
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID"] { response.headers[.init(name)!] = request.headers[name] }
      response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
      return response
    }, clock: time, store: MemoryOperationStore(), maxExchanges: 4, abort: { _ in }, trace: { trace in traces.withLock { $0.append(trace) } })
    let hanging = Task { await expectCode(.requestDeadline) { _ = try await client.probe("hanging") } }
    await gate.arrival()
    for _ in 0 ..< 2000 { if sleeps.withLock({ $0 > 0 }) { break }; await Task.yield() }
    for name in ["healthy-a", "healthy-b", "healthy-c"] {
      #expect(try await client.probe(name)?.acceptingStarts == true)
    }
    await clock.advance(by: .seconds(1)); await hanging.value
    for name in ["healthy-a", "healthy-b", "healthy-c"] {
      #expect(try await client.probe(name)?.acceptingStarts == true)
    }
    #expect(traces.withLock { $0.filter { $0.error == .capacityExceeded }.isEmpty })
    gate.release(); await client.shutdown()
  }

  @Test func exchangeAdmissionRefusalHasAReasonAndTraceWithoutDispatch() async throws {
    let gate = Pause(); let traces = Mutex<[OperationTrace]>([])
    let ledger = ExchangeLedger(fetch: .init { request in
      await gate.wait()
      var response = Response.text("ok")
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID"] { response.headers[.init(name)!] = request.headers[name] }
      response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
      return response
    }, clock: .continuous, capacity: 1, abort: { _ in }, trace: { trace in traces.withLock { $0.append(trace) } })
    var request = Request(url: URL(string: "https://memory.invalid/machine/v2/machines/phone")!)
    request.headers["X-Wuhu-Correlation-ID"] = UUID().uuidString
    request.headers["X-Wuhu-Request-ID"] = UUID().uuidString
    let firstRequest = request
    let first = Task { try await ledger.exchange(firstRequest, id: UUID(), timeout: .seconds(30), limit: 1024) }
    await gate.arrival()
    let refused = UUID()
    do {
      _ = try await ledger.exchange(request, id: refused, timeout: .seconds(30), limit: 1024)
      Issue.record("Saturated ledger admitted an exchange")
    } catch let error as OperationError {
      #expect(error.code == .capacityExceeded)
      #expect(error.message == "Exchange limit reached (1 outstanding requests)")
      #expect(error.details == ["reason": "exchangeLimit"])
    }
    let refusal = traces.withLock { $0.filter { $0.request == refused } }
    #expect(refusal.count == 1)
    #expect(refusal.first?.event == .failure)
    #expect(refusal.first?.error == .capacityExceeded)
    gate.release(); _ = try await first.value
    await ledger.shutdown()
  }
}
