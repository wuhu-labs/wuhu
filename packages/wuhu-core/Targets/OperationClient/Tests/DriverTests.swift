#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
@testable import OperationClient
import OperationProtocol
@testable import OperationRuntime
import Synchronization
import Testing

/// Writes `chunks` payloads of `size` bytes to `out`, then completes; with `echo` first copies `in` to `out` until its end;
/// with `wait` runs until stopped.
private struct EmitKind: OperationKind {
  struct Input: Codable, Sendable {
    var chunks = 0
    var size = 0
    var wait = false
    var echo = false
  }

  let descriptor = KindDescriptor(
    "emit.v1",
    inputSchema: ["type": "object"],
    resultSchema: ["type": "object"],
    inputChannels: [.init("in", windowBytes: 65536)],
    outputChannels: [.init("out", windowBytes: 65536)],
  )

  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    while input.echo, let payload = try await channels.read("in", upTo: 65536) {
      try await channels.send(payload, to: "out")
    }
    for index in 0 ..< input.chunks {
      try await channels.send(.init(data: Self.chunk(index, size: input.size)), to: "out")
    }
    while input.wait {
      try await cancellation.check()
      try await Task.sleep(for: .milliseconds(10))
    }
    return ["sent": .integer(input.chunks * input.size)]
  }

  static func chunk(_ index: Int, size: Int) -> Data { Data((0 ..< size).map { UInt8(($0 + index * 7) % 251) }) }
}

private func emit(chunks: Int = 0, size: Int = 0, wait: Bool = false, echo: Bool = false) -> StartRequest {
  .init(kind: "emit.v1", input: ["chunks": .integer(chunks), "size": .integer(size), "wait": .bool(wait), "echo": .bool(echo)])
}

private extension OperationLimits {
  /// A lease short enough that silence ends a test in about a second.
  static func short(lease: Int = 900, hold: Int = 200) -> Self {
    var limits = Self()
    limits.leaseMs = lease; limits.pollHoldMs = hold
    return limits
  }
}

/// The wire between the operations and one or more in-process agents: counts starts, records holds, and can fail or hang one machine.
final class Wire: Sendable {
  enum Mode: Sendable { case pass, fail, hang }
  let agents: [String: OperationAgent]
  let runs: [Task<Void, Never>]
  let modes = Mutex<[String: Mode]>([:])
  let posts = Mutex(0)
  let holds = Mutex<[Int]>([])
  /// Every request that reached a machine: its request id and correlation id headers.
  let headers = Mutex<[(path: String, request: String?, correlation: String?)]>([])
  /// What happens to the next matching request: the machine applies it and the answer is lost, it is refused unapplied, or
  /// it never arrives and never ends.
  enum Fault: Sendable { case loseAnswer, refuse(OperationError.Code), hang }
  let fault = Mutex<(match: @Sendable (Request) -> Bool, fault: Fault)?>(nil)
  /// How many answers carrying a verdict still go out without their final offsets, as an agent answers when its verdict is
  /// published before its channels' tails.
  let verdictsWithoutFinalOffsets = Mutex(0)

  init(_ machines: [String] = ["disk"], limits: OperationLimits = .short()) throws {
    var agents: [String: OperationAgent] = [:]
    for machine in machines { agents[machine] = try OperationAgent(machine: machine, kinds: [.init(EmitKind())], limits: limits, authorize: { _, _ in }) }
    self.agents = agents
    runs = agents.values.map { agent in Task { await agent.run() } }
  }

  var agent: OperationAgent { agents.values.first! }

  func set(_ machine: String, _ mode: Mode) { modes.withLock { $0[machine] = mode } }

  var fetch: FetchClient {
    FetchClient { request in
      let parts = request.url.pathComponents
      guard let index = parts.firstIndex(of: "machines"), index + 1 < parts.count, let agent = self.agents[parts[index + 1]] else {
        throw OperationError(.unknownMachine)
      }
      switch self.modes.withLock({ $0[parts[index + 1]] ?? .pass }) {
      case .pass: break
      case .fail: throw OperationError(.transport, message: "connection refused")
      case .hang:
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
      }
      if request.method == .post { self.posts.withLock { $0 += 1 } }
      self.headers.withLock { $0.append((request.url.path, request.headers["X-Wuhu-Request-ID"], request.headers["X-Wuhu-Correlation-ID"])) }
      if let hold = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "holdMs" })?.value.flatMap(Int.init) {
        self.holds.withLock { $0.append(hold) }
      }
      if let armed = self.fault.withLock({ armed -> Fault? in
        guard let current = armed, current.match(request) else { return nil }
        armed = nil; return current.fault
      }) {
        switch armed {
        case .loseAnswer:
          _ = try await agent.handler(request)
          throw OperationError(.transport, message: "answer lost")
        case let .refuse(code): throw OperationError(code)
        case .hang:
          try await Task.sleep(for: .seconds(3600))
          throw CancellationError()
        }
      }
      let response = try await agent.handler(request)
      guard self.verdictsWithoutFinalOffsets.withLock({ $0 > 0 }) else { return response }
      let body = try await response.body.data()
      guard let snapshot = try? JSONDecoder().decode(OperationSnapshot.self, from: body), snapshot.verdict != nil,
            !snapshot.finalOffsets.isEmpty, self.verdictsWithoutFinalOffsets.withLock({ count in
              guard count > 0 else { return false }
              count -= 1; return true
            })
      else { return Response(status: response.status, headers: response.headers, body: .bytes(body)) }
      let withheld = OperationSnapshot(
        operation: snapshot.operation, verdict: snapshot.verdict, terminalToken: snapshot.terminalToken, finalOffsets: [:],
        outputConsumed: snapshot.outputConsumed, channel: snapshot.channel, from: snapshot.from, through: snapshot.through,
        payload: snapshot.payload, channelEnd: snapshot.channelEnd, bufferReservationBytes: snapshot.bufferReservationBytes,
      )
      var answer = try Response.json(withheld, status: response.status)
      for name in ["X-Wuhu-Correlation-ID", "X-Wuhu-Request-ID", "X-Wuhu-Agent-Instance"] {
        answer.headers[.init(name)!] = response.headers[.init(name)!]
      }
      return answer
    }
  }

  func operations(store: any OperationStore = MemoryOperationStore(), tunnel: TunnelLanes = TunnelLanes()) throws -> MachineOperations {
    try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: store, tunnel: tunnel)
  }

  func close() async {
    for agent in agents.values { await agent.shutdown() }
    for run in runs { run.cancel() }
  }
}

/// A store whose claims take a while, as a database's do, so concurrent starts interleave between admission and claim.
private struct SlowClaims: OperationStore {
  let base = MemoryOperationStore()
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim {
    try await Task.sleep(for: .milliseconds(50))
    return try await base.claim(owner, record: record)
  }

  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws { try await base.save(record, appending: chunk) }
  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws { try await base.trim(record, removing: sequences) }
}

/// A store whose saves fail while `failing` is above zero, one failure each, as a database briefly unavailable does.
private final class FlakySaves: OperationStore, Sendable {
  let base = MemoryOperationStore()
  let failing = Mutex(0)
  let onFailure: @Sendable () -> Void
  init(onFailure: @escaping @Sendable () -> Void = {}) { self.onFailure = onFailure }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await base.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws {
    let fail = failing.withLock { count in
      guard count > 0 else { return false }
      count -= 1; return true
    }
    if fail { onFailure(); throw OperationError(.storeUnavailable, message: "database is locked") }
    try await base.save(record, appending: chunk)
  }

  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws { try await base.trim(record, removing: sequences) }
}

/// A store that can hold its output saves until released, and counts the writes it took.
private final class ParkedSaves: OperationStore, Sendable {
  let base = MemoryOperationStore()
  let parking = Mutex(false)
  /// Claims wait for `release` too while set.
  let parkingClaims = Mutex(false)
  let parked = Mutex(0)
  let writes = Mutex(0)
  private let gate = AsyncStream<Void>.makeStream()

  func release() { gate.continuation.finish() }
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await base.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim {
    if parkingClaims.withLock({ $0 }) {
      parked.withLock { $0 += 1 }
      for await _ in gate.stream {}
    }
    return try await base.claim(owner, record: record)
  }

  func read(_ id: UUID) async throws -> ClientRecord { try await base.read(id) }
  func live() async throws -> [StoredOperation] { try await base.live() }
  func setAside(_ id: UUID) async throws { try await base.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws {
    if chunk != nil, parking.withLock({ $0 }) {
      parked.withLock { $0 += 1 }
      for await _ in gate.stream {}
    }
    try await base.save(record, appending: chunk)
    writes.withLock { $0 += 1 }
  }

  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws {
    try await base.trim(record, removing: sequences)
    writes.withLock { $0 += 1 }
  }
}

/// Reads and acknowledges output until the operation is drained, returning the bytes in order.
private func drain(_ operation: OperationClient.Operation) async throws -> Data {
  var bytes = Data()
  var after: UInt64?
  while let chunks = try await operation.output(after: after) {
    for chunk in chunks {
      bytes.append(chunk.payload.data ?? Data())
      after = chunk.sequence
      try await operation.acknowledge(chunk)
    }
  }
  return bytes
}

private func eventually(_ seconds: Double = 5, _ condition: () async throws -> Bool) async throws -> Bool {
  let end = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < end {
    if try await condition() { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return try await condition()
}

/// Opens once, for every waiter, now and later.
private final class Signal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream() }
  func fire() { continuation.finish() }
  func wait() async { for await _ in stream {} }
}

/// Leaves `owner`'s operation concluded by a diagnostic while the machine still runs it.
private func conclude(_ owner: OperationOwner, wire: Wire, store: MemoryOperationStore) async throws {
  let concluding = Mutex(false)
  let fetch = FetchClient { request in
    if (request.url.query ?? "").contains("channel=out"), concluding.withLock({ $0 }) { throw OperationError(.invalidInput) }
    return try await wire.fetch(request)
  }
  let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: store, tunnel: TunnelLanes())
  let operation = try await operations.open(owner, machine: "disk", start: emit(wait: true))
  concluding.withLock { $0 = true }
  await #expect(throws: OperationError.self) { try await operation.verdict() }
  await operations.shutdown()
}

/// Holds an abandon's write (the record turning `discard`) until `release`.
private final class HeldAbandon: OperationStore {
  let memory = MemoryOperationStore()
  let writing = Signal(), release = Signal()
  let written = Mutex(false)
  func lookup(_ owner: OperationOwner) async throws -> ClientRecord? { try await memory.lookup(owner) }
  func claim(_ owner: OperationOwner, record: ClientRecord) async throws -> OperationClaim { try await memory.claim(owner, record: record) }
  func read(_ id: UUID) async throws -> ClientRecord { try await memory.read(id) }
  func live() async throws -> [StoredOperation] { try await memory.live() }
  func setAside(_ id: UUID) async throws { try await memory.setAside(id) }
  func save(_ record: ClientRecord, appending chunk: OutputChunk?) async throws {
    try await held(record) { try await memory.save(record, appending: chunk) }
  }

  func trim(_ record: ClientRecord, removing sequences: [UInt64]) async throws {
    try await held(record) { try await memory.trim(record, removing: sequences) }
  }

  private func held(_ record: ClientRecord, _ write: () async throws -> Void) async throws {
    guard record.discard else { return try await write() }
    writing.fire()
    await release.wait()
    try await write()
    written.withLock { $0 = true }
  }
}

private func expected(chunks: Int, size: Int, from first: Int = 0) -> Data {
  (first ..< chunks).reduce(into: Data()) { $0.append(EmitKind.chunk($1, size: size)) }
}

@Suite(.timeLimit(.minutes(1))) struct DriverTests {
  /// Audit 11: claimed -> running -> terminal -> drained -> acknowledged -> retired, and the driver goes away with it.
  @Test func operationRetiresOnceItsOutputIsAcknowledged() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let operations = try wire.operations(store: store)
    let operation = try await operations.open(.init(scope: "test", key: "retire"), machine: "disk", start: emit(chunks: 3, size: 1000))
    #expect(try await drain(operation) == expected(chunks: 3, size: 1000))
    let verdict = try await operation.verdict()
    #expect(verdict.tag == .completed)
    #expect(try await eventually { await operations.running == 0 })
    #expect(try await store.read(operation.id).retired)
    // The machine drops a settled operation.
    #expect(await wire.agent.inspect(operation.id)?.outputConsumed ?? true)
    #expect(wire.posts.withLock { $0 } == 1)
    await operations.shutdown(); await wire.close()
  }

  /// The machine drops an operation once it is settled, so a terminal acknowledgement whose answer was lost finds it gone on
  /// retry: that is the retirement, not a diagnostic.
  @Test func lostTerminalAcknowledgementStillRetires() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let operations = try wire.operations(store: store)
    wire.fault.withLock { $0 = ({ $0.url.query?.contains("terminalAck=") == true }, .loseAnswer) }
    let operation = try await operations.open(.init(scope: "test", key: "settled"), machine: "disk", start: emit(chunks: 2, size: 100))
    #expect(try await drain(operation) == expected(chunks: 2, size: 100))
    #expect(try await eventually { await operations.running == 0 })
    #expect(wire.fault.withLock { $0 == nil })
    let record = try await store.read(operation.id)
    #expect(record.retired)
    #expect(record.diagnostic == nil)
    #expect(try await operation.verdict().tag == .completed)
    await operations.shutdown(); await wire.close()
  }

  /// A verdict that reaches the server before its channels' final offsets does not drain the operation: the output still
  /// arrives in full before it retires.
  @Test func verdictBeforeFinalOffsetsStillDeliversAllOutput() async throws {
    let wire = try Wire()
    wire.verdictsWithoutFinalOffsets.withLock { $0 = 3 }
    let store = MemoryOperationStore()
    let operations = try wire.operations(store: store)
    let operation = try await operations.open(.init(scope: "test", key: "verdict-first"), machine: "disk", start: emit(chunks: 4, size: 10000))
    #expect(try await drain(operation) == expected(chunks: 4, size: 10000))
    #expect(try await operation.verdict().tag == .completed)
    #expect(try await eventually { await operations.running == 0 })
    #expect(wire.verdictsWithoutFinalOffsets.withLock { $0 } < 3)
    #expect(try await store.read(operation.id).retired)
    await operations.shutdown(); await wire.close()
  }

  /// An operation concluded by a diagnostic while the machine still runs it gets the abandoning stop anyway, so it does not run
  /// on until its lease lapses, and its retained output goes from the store as any abandoned operation's does.
  @Test func abandoningAConcludedOperationStopsItAndDropsItsOutput() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let operations = try wire.operations(store: store)
    // One chunk: retention leaves no room for another full poll, so a second would wait for the consumer.
    let operation = try await operations.open(.init(scope: "test", key: "concluded"), machine: "disk", start: emit(chunks: 1, size: 200, wait: true))
    #expect(try await eventually { try await store.read(operation.id).retainedBytes("out") == 200 })
    // The output lane waits for the consumer now; the state poll gets the conclusive answer.
    wire.fault.withLock { $0 = ({ ($0.url.query ?? "").contains("holdMs") && !($0.url.query ?? "").contains("channel=") }, .refuse(.invalidInput)) }
    await #expect(throws: OperationError.self) { try await operation.verdict() }
    try await operation.abandon("gone")
    #expect(try await eventually { await wire.agent.inspect(operation.id)?.verdict?.reason == "gone" })
    #expect(try await store.read(operation.id).output.isEmpty)
    await operations.shutdown(); await wire.close()
  }

  /// The abandoning stop of a concluded operation outlives the driver's own end: abandoned while the control lane is still in
  /// an exchange, with that stop lost until the driver has ended, it is retried and reaches the machine.
  @Test func theAbandoningStopOutlivesTheDriversEnd() async throws {
    let wire = try Wire(limits: .short(lease: 60000))
    let operations = Mutex<MachineOperations?>(nil)
    let inputHeld = Signal(), inputReleased = Signal(), stopLost = Signal(), stopped = Signal()
    let concluding = Mutex(false)
    let fetch = FetchClient { request in
      let query = request.url.query ?? ""
      if request.method == .put, request.url.path.hasSuffix("/inputs/in") {
        inputHeld.fire()
        await inputReleased.wait()
      }
      if query.contains("channel=out"), concluding.withLock({ value in defer { value = false }; return value }) {
        throw OperationError(.invalidInput)
      }
      if request.method == .put, request.url.path.hasSuffix("/stop") {
        guard let made = operations.withLock({ $0 }), await made.running == 0 else {
          stopLost.fire()
          throw OperationError(.transport, message: "stop lost")
        }
        let response = try await wire.fetch(request)
        stopped.fire()
        return response
      }
      return try await wire.fetch(request)
    }
    let made = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: MemoryOperationStore(), tunnel: TunnelLanes())
    operations.withLock { $0 = made }
    let operation = try await made.open(.init(scope: "test", key: "abandoned"), machine: "disk", start: emit(wait: true))
    // The control lane takes the input and is held in that exchange while the output lane meets the conclusive answer.
    try await operation.write("in", ChannelPayload(data: Data("x".utf8)))
    await inputHeld.wait()
    concluding.withLock { $0 = true }
    await #expect(throws: OperationError.self) { try await operation.verdict() }
    try await operation.abandon("gone")
    await stopLost.wait()
    inputReleased.fire()
    await stopped.wait()
    await made.shutdown(); await wire.close()
  }

  /// The service's shutdown owns an abandoning stop that outlived its driver: shutdown cancels that stop's exchange before it
  /// returns, and reopening the record meanwhile finds the same driver rather than a second writer.
  @Test func shutdownEndsAnAbandoningStopThatOutlivedItsDriver() async throws {
    let wire = try Wire(limits: .short(lease: 60000))
    let stopHeld = Signal(), never = Signal()
    let stopCancelled = Mutex(false)
    let concluding = Mutex(false)
    let fetch = FetchClient { request in
      if (request.url.query ?? "").contains("channel=out"), concluding.withLock({ value in defer { value = false }; return value }) {
        throw OperationError(.invalidInput)
      }
      if request.method == .put, request.url.path.hasSuffix("/stop") {
        await withTaskCancellationHandler {
          stopHeld.fire()
          await never.wait()
        } onCancel: { stopCancelled.withLock { $0 = true } }
        throw CancellationError()
      }
      return try await wire.fetch(request)
    }
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: MemoryOperationStore(), tunnel: TunnelLanes())
    let owner = OperationOwner(scope: "test", key: "abandoned")
    let operation = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    concluding.withLock { $0 = true }
    await #expect(throws: OperationError.self) { try await operation.verdict() }
    try await operation.abandon("gone")
    await stopHeld.wait()
    let reopened = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    #expect(reopened.driver === operation.driver)
    await operations.shutdown()
    #expect(stopCancelled.withLock { $0 })
    await wire.close()
  }

  /// An `open` while an abandon of a concluded operation is writing gets the abandoning driver, not a second writer.
  @Test func openDuringAnAbandonFindsTheAbandoningDriver() async throws {
    let wire = try Wire(limits: .short(lease: 60000))
    let store = HeldAbandon()
    let owner = OperationOwner(scope: "test", key: "abandon-open")
    try await conclude(owner, wire: wire, store: store.memory)
    let operations = try wire.operations(store: store)
    let operation = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    let abandoning = Task { try await operation.abandon("gone") }
    await store.writing.wait()
    let reopened = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    #expect(reopened.driver === operation.driver)
    store.release.fire()
    try await abandoning.value
    await operations.shutdown(); await wire.close()
  }

  /// A shutdown while an abandon of a concluded operation is writing returns only once that write is over.
  @Test func shutdownDuringAnAbandonOutlastsItsWrite() async throws {
    let wire = try Wire(limits: .short(lease: 60000))
    let store = HeldAbandon()
    let owner = OperationOwner(scope: "test", key: "abandon-shutdown")
    try await conclude(owner, wire: wire, store: store.memory)
    let operations = try wire.operations(store: store)
    let operation = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    let abandoning = Task { try? await operation.abandon("gone") }
    await store.writing.wait()
    let shutdown = Task {
      await operations.shutdown()
      return store.written.withLock { $0 }
    }
    store.release.fire()
    #expect(await shutdown.value)
    await abandoning.value
    await wire.close()
  }

  /// A `setAside` while an abandon of a concluded operation is writing ends that abandon: no stop runs on past it, and no tunnel
  /// lane stays held.
  @Test func setAsideDuringAnAbandonLeavesNoStopOrLane() async throws {
    let wire = try Wire(limits: .short(lease: 60000))
    let store = HeldAbandon()
    let owner = OperationOwner(scope: "test", key: "abandon-aside")
    try await conclude(owner, wire: wire, store: store.memory)
    let stops = Mutex((issued: 0, ended: 0))
    let fetch = FetchClient { request in
      guard request.method == .put, request.url.path.hasSuffix("/stop") else { return try await wire.fetch(request) }
      stops.withLock { $0.issued += 1 }
      await withTaskCancellationHandler { await Signal().wait() } onCancel: { stops.withLock { $0.ended += 1 } }
      throw CancellationError()
    }
    // Room for exactly one operation's lanes.
    let tunnel = TunnelLanes { _ in TunnelLanes.describeStreams + 2 }
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: fetch, store: store, tunnel: tunnel)
    let operation = try await operations.open(owner, machine: "disk", start: emit(wait: true))
    let abandoning = Task { try? await operation.abandon("gone") }
    await store.writing.wait()
    let aside = Task { try await operations.setAside(operation) }
    store.release.fire()
    try await aside.value
    await abandoning.value
    let ran = stops.withLock { $0 }
    #expect(ran.issued == ran.ended)
    _ = try await operations.open(.init(scope: "test", key: "after-aside"), machine: "disk", start: emit(wait: true))
    await operations.shutdown(); await wire.close()
  }

  /// A store that fails to keep the answer to an accepted start does not turn it into a refusal: the opener gets the running
  /// operation, which can be stopped, and the machine got one start.
  @Test func storeFailureAfterAnAcceptedStartKeepsTheOperation() async throws {
    let wire = try Wire()
    let store = FlakySaves()
    store.failing.withLock { $0 = 1 }
    let operations = try wire.operations(store: store)
    let operation = try await operations.open(.init(scope: "test", key: "flaky"), machine: "disk", start: emit(wait: true))
    #expect(store.failing.withLock { $0 } == 0)
    try await operation.stop("done")
    #expect(try await operation.verdict().reason == "done")
    #expect(wire.posts.withLock { $0 } == 1)
    await operations.shutdown(); await wire.close()
  }

  /// Shutdown returns only once no write of its drivers is in flight, and nothing of them writes after: a later instance over the
  /// same store is the operation's only writer and resumes its output exactly.
  @Test func shutdownLeavesNoWriterBehind() async throws {
    let wire = try Wire()
    let store = ParkedSaves()
    let owner = OperationOwner(scope: "test", key: "fenced")
    let first = try wire.operations(store: store)
    store.parking.withLock { $0 = true }
    let operation = try await first.open(owner, machine: "disk", start: emit(chunks: 3, size: 100))
    #expect(try await eventually { store.parked.withLock { $0 } > 0 })
    let stopping = Task { await first.shutdown() }
    try await Task.sleep(for: .milliseconds(200))
    store.parking.withLock { $0 = false }
    store.release()
    await stopping.value
    let writes = store.writes.withLock { $0 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(store.writes.withLock { $0 } == writes)
    #expect(operation.owner == owner)
    let second = try wire.operations(store: store)
    let resumed = try await second.resume()
    #expect(resumed.map(\.owner) == [owner])
    #expect(try await drain(#require(resumed[0].operation)) == expected(chunks: 3, size: 100))
    #expect(try await #require(resumed[0].operation).verdict().tag == .completed)
    await second.shutdown(); await wire.close()
  }

  /// An open still waiting on another open of the same owner when the instance shuts down starts nothing on it: no driver of
  /// the closed instance is left running, and nothing is written after shutdown returned.
  @Test func anOpenWaitingThroughShutdownStartsNothing() async throws {
    let wire = try Wire()
    let store = ParkedSaves()
    let owner = OperationOwner(scope: "test", key: "waiting")
    let operations = try wire.operations(store: store)
    store.parkingClaims.withLock { $0 = true }
    let first = Task { try await operations.open(owner, machine: "disk", start: emit(chunks: 3, size: 100)) }
    #expect(try await eventually { store.parked.withLock { $0 } > 0 })
    let second = Task { try await operations.open(owner, machine: "disk", start: emit(chunks: 3, size: 100)) }
    try await Task.sleep(for: .milliseconds(100))
    let stopping = Task { await operations.shutdown() }
    try await Task.sleep(for: .milliseconds(100))
    store.release()
    await stopping.value
    _ = try? await first.value
    await #expect { _ = try await second.value } throws: { ($0 as? OperationError)?.code == .requestCancelled }
    let writes = store.writes.withLock { $0 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(store.writes.withLock { $0 } == writes)
    #expect(await operations.running == 0)
    await wire.close()
  }

  /// Unacknowledged output stays within the channel window; the driver takes more only as the consumer acknowledges.
  @Test func retainedOutputNeverExceedsTheChannelWindow() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    let operation = try await operations.open(.init(scope: "test", key: "window"), machine: "disk", start: emit(chunks: 4, size: 65536))
    try await Task.sleep(for: .milliseconds(400))
    let record = await operation.record
    #expect(record.retainedBytes("out") <= 65536)
    #expect(record.snapshot?.verdict == nil)
    #expect(try await drain(operation) == expected(chunks: 4, size: 65536))
    #expect(try await operation.verdict().tag == .completed)
    await operations.shutdown(); await wire.close()
  }

  /// Audit 7 and 9: a machine that fails every exchange, or never answers one, ends the operation with a lease-silence
  /// diagnostic about one lease after its last answer: each exchange's deadline is real and retries stop at the lease.
  @Test(arguments: [Wire.Mode.fail, .hang]) func silentMachineEndsTheOperationAtItsLease(mode: Wire.Mode) async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    let operation = try await operations.open(.init(scope: "test", key: "silent"), machine: "disk", start: emit(wait: true))
    wire.set("disk", mode)
    let started = ContinuousClock.now
    do {
      _ = try await operation.verdict()
      Issue.record("Expected a lease-silence diagnostic")
    } catch let error as OperationError {
      #expect(error.code == .unknownOperation)
      #expect(error.details?.object?["reason"] == "leaseSilence")
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(try await eventually { await operations.running == 0 })
    await operations.shutdown(); await wire.close()
  }

  /// Audit 10: one table sorts every exchange failure; codes this build does not know conclude.
  @Test func failuresAreSortedByOneTable() {
    for code: OperationError.Code in [.transport, .requestDeadline, .requestCancelled, .machineUnavailable, .supervisorUnavailable, .capacityExceeded] {
      #expect(disposition(code) == .retry)
    }
    for code: OperationError.Code in [.unknownMachine, .machineNotAuthorized, .unknownOperation, .offsetExpired, .invalidResponse, .unsupportedProtocol, .leaving] {
      #expect(disposition(code) == .conclude)
    }
    #expect(disposition(.init(rawValue: "codeFromANewerMachine")) == .conclude)
  }

  /// Audit 5: concurrent opens of one owner, racing a resume, dispatch the start once.
  @Test func racingOpensAndResumeDispatchOnce() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    let owner = OperationOwner(scope: "test", key: "race")
    let ids = try await withThrowingTaskGroup(of: UUID?.self) { tasks in
      for _ in 0 ..< 8 { tasks.addTask { try await operations.open(owner, machine: "disk", start: emit(chunks: 1, size: 10)).id } }
      tasks.addTask { _ = try await operations.resume(); return nil }
      return try await tasks.reduce(into: Set<UUID>()) { if let id = $1 { $0.insert(id) } }
    }
    #expect(ids.count == 1)
    #expect(wire.posts.withLock { $0 } == 1)
    await operations.shutdown(); await wire.close()
  }

  /// Audit 12: one machine failing every exchange leaves another machine's operations untouched.
  @Test func failingMachineDoesNotStallAnother() async throws {
    let wire = try Wire(["good", "bad"])
    let operations = try wire.operations()
    let bad = try await operations.open(.init(scope: "test", key: "bad"), machine: "bad", start: emit(wait: true))
    wire.set("bad", .fail)
    let good = try await operations.open(.init(scope: "test", key: "good"), machine: "good", start: emit(chunks: 2, size: 500))
    #expect(try await drain(good) == expected(chunks: 2, size: 500))
    #expect(try await good.verdict().tag == .completed)
    await #expect(throws: OperationError.self) { try await bad.verdict() }
    await operations.shutdown(); await wire.close()
  }

  /// Audit 14: held polls never hold past the machine's poll hold or a third of its lease, whichever is shorter.
  @Test func holdsFollowTheMachinesLimits() async throws {
    let wire = try Wire(limits: .short(lease: 900, hold: 600))
    let operations = try wire.operations()
    let operation = try await operations.open(.init(scope: "test", key: "holds"), machine: "disk", start: emit(wait: true))
    try await Task.sleep(for: .milliseconds(800))
    try await operation.stop("test")
    _ = try await operation.verdict()
    let holds = wire.holds.withLock { $0 }
    #expect(holds.contains { $0 > 0 })
    #expect(holds.allSatisfy { $0 <= 300 })
    await operations.shutdown(); await wire.close()
  }

  /// Audit 4: a restart mid-output resumes from the store: the bytes the consumer had not acknowledged arrive again, exactly,
  /// then the rest, and the machine's own verdict.
  @Test func restartMidOutputResumesExactBytes() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let owner = OperationOwner(scope: "test", key: "restart")
    let first = try wire.operations(store: store)
    let operation = try await first.open(owner, machine: "disk", start: emit(chunks: 6, size: 30000))
    var read = Data()
    var after: UInt64?
    acknowledged: while let chunks = try await operation.output(after: after) {
      for chunk in chunks {
        read.append(chunk.payload.data ?? Data())
        after = chunk.sequence
        try await operation.acknowledge(chunk)
        if read.count >= 30000 { break acknowledged }
      }
    }
    await first.shutdown()
    let second = try wire.operations(store: store)
    let resumed = try await second.resume()
    #expect(resumed.map(\.owner) == [owner])
    let rest = try await drain(#require(resumed[0].operation))
    #expect(read + rest == expected(chunks: 6, size: 30000))
    #expect(try await #require(resumed[0].operation).verdict().tag == .completed)
    #expect(wire.posts.withLock { $0 } == 1)
    await second.shutdown(); await wire.close()
  }

  /// A start whose answer is lost is retried as the same start: the machine runs it once.
  @Test func lostStartAnswerRunsOnce() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    wire.fault.withLock { $0 = ({ $0.method == .post }, .loseAnswer) }
    let operation = try await operations.open(.init(scope: "test", key: "lost-start"), machine: "disk", start: emit(chunks: 2, size: 100))
    #expect(try await drain(operation) == expected(chunks: 2, size: 100))
    #expect(try await operation.verdict().tag == .completed)
    #expect(await wire.agent.operations.count <= 1)
    await operations.shutdown(); await wire.close()
  }

  /// A start the machine refuses is the opener's typed error; nothing runs.
  @Test func refusedStartIsTheOpenersError() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    wire.fault.withLock { $0 = ({ $0.method == .post }, .refuse(.capacityExceeded)) }
    await #expect { _ = try await operations.open(.init(scope: "test", key: "refused"), machine: "disk", start: emit(chunks: 1, size: 10)) } throws: {
      ($0 as? OperationError)?.code == .capacityExceeded
    }
    #expect(await wire.agent.operations.isEmpty)
    #expect(wire.posts.withLock { $0 } == 1)
    await operations.shutdown(); await wire.close()
  }

  /// A claim whose start never left before the server stopped is never sent after the restart: the operation ends with a
  /// diagnostic and the machine runs nothing.
  @Test func claimLostBeforeItsStartNeverDispatchesAfterRestart() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let owner = OperationOwner(scope: "test", key: "unsent")
    let first = try wire.operations(store: store)
    wire.fault.withLock { $0 = ({ $0.method == .post }, .hang) }
    let opening = Task { try await first.open(owner, machine: "disk", start: emit(chunks: 1, size: 10)) }
    #expect(try await eventually { try await store.lookup(owner) != nil })
    await first.shutdown()
    opening.cancel()
    let second = try wire.operations(store: store)
    let resumed = try await second.resume()
    #expect(resumed.map(\.owner) == [owner])
    await #expect(throws: OperationError.self) { try await #require(resumed[0].operation).verdict() }
    // Only the start that never arrived.
    #expect(wire.posts.withLock { $0 } == 1)
    #expect(await wire.agent.operations.isEmpty)
    await second.shutdown(); await wire.close()
  }

  /// Input whose receipt is lost is written again from the same offset: the machine takes each byte once.
  @Test func lostInputReceiptDeliversBytesOnce() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    let operation = try await operations.open(.init(scope: "test", key: "input"), machine: "disk", start: emit(echo: true))
    wire.fault.withLock { $0 = ({ $0.method == .put && $0.url.path.contains("/inputs/") }, .loseAnswer) }
    try await operation.write("in", .init(data: Data("hello ".utf8)))
    try await operation.write("in", .init(data: Data("world".utf8)), end: true)
    #expect(wire.fault.withLock { $0 == nil })
    #expect(try await drain(operation) == Data("hello world".utf8))
    #expect(try await operation.verdict().tag == .completed)
    await operations.shutdown(); await wire.close()
  }

  /// Every exchange carries its own request id and the operation's one correlation id.
  @Test func exchangesCarryUniqueRequestIdsAndOneCorrelation() async throws {
    let wire = try Wire()
    let operations = try wire.operations()
    _ = try await operations.describe("disk")
    wire.headers.withLock { $0 = [] }
    let operation = try await operations.open(.init(scope: "test", key: "trace"), machine: "disk", start: emit(chunks: 2, size: 10))
    _ = try await drain(operation)
    #expect(try await eventually { await operations.running == 0 })
    let headers = wire.headers.withLock { $0 }.filter { $0.path.contains(operation.id.uuidString) }
    #expect(headers.count > 2)
    #expect(Set(headers.compactMap(\.request)).count == headers.count)
    #expect(Set(headers.compactMap(\.correlation)) == [await operation.record.correlation.uuidString])
    await operations.shutdown(); await wire.close()
  }

  /// Audit 1: an operation that would not fit the machine's tunnel is refused before it is claimed, with a typed reason.
  @Test func startPastTheTunnelIsRefusedTyped() async throws {
    let wire = try Wire()
    let store = MemoryOperationStore()
    let operations = try wire.operations(store: store, tunnel: TunnelLanes { _ in TunnelLanes.describeStreams + 2 })
    _ = try await operations.open(.init(scope: "test", key: "fits"), machine: "disk", start: emit(wait: true))
    do {
      _ = try await operations.open(.init(scope: "test", key: "past"), machine: "disk", start: emit(wait: true))
      Issue.record("Expected a tunnel capacity refusal")
    } catch let error as OperationError {
      #expect(error.code == .capacityExceeded)
      #expect(error.details?.object?["reason"] == "tunnelStreams")
    }
    #expect(try await store.lookup(.init(scope: "test", key: "past")) == nil)
    #expect(wire.posts.withLock { $0 } == 1)
    await operations.shutdown(); await wire.close()
  }

  /// Concurrent starts share the tunnel's room, also when they come through different instances (one per group) sharing its
  /// lanes: exactly as many as fit are admitted, however their claims interleave.
  @Test func concurrentStartsFitTheTunnelTogether() async throws {
    let wire = try Wire()
    let tunnel = TunnelLanes { _ in TunnelLanes.describeStreams + 2 * 2 }
    let groups = try [wire.operations(store: SlowClaims(), tunnel: tunnel), wire.operations(store: SlowClaims(), tunnel: tunnel)]
    let admitted = await withTaskGroup(of: Bool.self) { tasks in
      for index in 0 ..< 6 {
        let operations = groups[index % 2]
        tasks.addTask { (try? await operations.open(.init(scope: "test", key: "fit-\(index)"), machine: "disk", start: emit(wait: true))) != nil }
      }
      return await tasks.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    #expect(admitted == 2)
    #expect(wire.posts.withLock { $0 } == 2)
    for operations in groups { await operations.shutdown() }
    await wire.close()
  }
}

extension DriverTests {
  @Test func databaseWaitLongerThanLeaseDoesNotExpireTheNextExchange() async throws {
    let wire = try Wire()
    let now = Mutex(Duration.zero)
    let zeroDeadlines = Mutex(0)
    let store = FlakySaves { now.withLock { $0 += .seconds(120) } }
    store.failing.withLock { $0 = 1 }
    let clock = OperationClock(now: { now.withLock { $0 } }, sleep: { duration in
      if duration <= .zero { zeroDeadlines.withLock { $0 += 1 } }
      try await ContinuousClock().sleep(for: duration)
    })
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: wire.fetch, store: store, clock: clock)
    let operation = try await operations.open(.init(scope: "test", key: "delayed-save"), machine: "disk", start: emit(chunks: 2, size: 10))
    #expect(try await drain(operation) == expected(chunks: 2, size: 10))
    #expect(try await operation.verdict().tag == .completed)
    #expect(zeroDeadlines.withLock { $0 } == 0)
    await operations.shutdown(); await wire.close()
  }
}

extension DriverTests {
  @Test func suspendedOutputSaveDoesNotConcludeLeaseSilenceOnAnotherLane() async throws {
    let wire = try Wire()
    let store = ParkedSaves()
    let failing = Mutex(false)
    let operations = try MachineOperations(origin: URL(string: "https://memory.invalid")!, fetch: FetchClient { request in
      if failing.withLock({ $0 }) { throw OperationError(.transport) }
      return try await wire.fetch(request)
    }, store: store)
    store.parking.withLock { $0 = true }
    let operation = try await operations.open(.init(scope: "test", key: "suspended-save"), machine: "disk", start: emit(chunks: 3, size: 100))
    #expect(try await eventually { store.parked.withLock { $0 } > 0 })
    failing.withLock { $0 = true }
    try await ContinuousClock().sleep(for: .milliseconds(1500))
    failing.withLock { $0 = false }
    store.parking.withLock { $0 = false }; store.release()
    #expect(try await drain(operation) == expected(chunks: 3, size: 100))
    #expect(try await operation.verdict().tag == .completed)
    await operations.shutdown(); await wire.close()
  }
}
