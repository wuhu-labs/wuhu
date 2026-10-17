#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationTrace
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict
import TaskLifetime

/// A handle on one operation. Output arrives in arrival order across channels and stays retained, durably, until acknowledged;
/// every call works the same before and after a server restart.
public struct Operation: Sendable {
  public let id: UUID
  public let owner: OperationOwner
  let driver: OperationDriver
  let operations: MachineOperations

  public var record: ClientRecord { get async { await driver.record } }
  /// Retained chunks above `after` (a chunk sequence), waiting for some; nil once every channel is drained past `after`.
  /// Throws the operation's diagnostic when it ended without one.
  public func output(after: UInt64?) async throws -> [OutputChunk]? { try await driver.output(after: after) }
  /// The consumer is done with the channel through `through`: it leaves retention and the driver may take more.
  public func acknowledge(channel: String, through: Offset) async throws { try await driver.acknowledge(channel, through: through) }
  public func acknowledge(_ chunk: OutputChunk) async throws { try await driver.acknowledge(chunk.channel, through: chunk.through) }
  /// Returns once the write is durable; the driver delivers it. `operationEnded` once the operation stopped or ended.
  public func write(_ channel: String, _ payload: ChannelPayload, end: Bool = false) async throws { try await driver.write(channel, payload: payload, end: end) }
  /// Durable stop intent; the first reason wins. `consumer`, when given, replaces the record's consumer state in the same write.
  public func stop(_ reason: String, consumer: JSONValue? = nil) async throws { try await driver.stop(reason, consumer: consumer) }
  /// Stop, and drop the output: nobody will read it. `consumer`, when given, replaces the record's consumer state in the same write.
  public func abandon(_ reason: String, consumer: JSONValue? = nil) async throws { try await operations.abandon(self, reason, consumer: consumer) }
  /// The machine's verdict; throws the diagnostic when the operation ended without one.
  public func verdict() async throws -> Verdict { try await driver.verdict() }
}

/// What `resume` found for one live record: its operation, driven again, or the record set aside because it cannot be read.
public enum ResumedOperation: Sendable {
  case live(Operation)
  case setAside(OperationOwner, OperationError)

  public var owner: OperationOwner {
    switch self {
    case let .live(operation): operation.owner
    case let .setAside(owner, _): owner
    }
  }

  public var operation: Operation? {
    if case let .live(operation) = self { operation } else { nil }
  }
}

/// Every machine operation of one store: admission, one driver per operation, and machine descriptions. Deep inside, shallow
/// outside: `open` is idempotent by owner and resumes after a restart.
public actor MachineOperations {
  private let taskScope = TaskScope()
  static let describeDeadline: Duration = .seconds(5)

  private struct Kept {
    let driver: OperationDriver
    var abandons = 0
    var stop: Task<Void, Never>?
  }

  private struct Entry {
    let driver: OperationDriver
    let owner: OperationOwner
    let machine: String
    let lanes: Int
  }

  let link: MachineLink
  let store: any OperationStore
  let tunnel: TunnelLanes
  private var drivers: [UUID: Entry] = [:]
  /// Drivers kept past their own end, by operation: while an abandon of the operation runs, then while its abandoning stop does
  /// (holding a tunnel lane). `open` reattaches to one, and `shutdown` and `setAside` end it.
  private var kept: [UUID: Kept] = [:]
  private var opening: [OperationOwner: Task<Operation, any Error>] = [:]
  private var descriptions: [String: (description: MachineDescription, at: Duration)] = [:]
  private var closed = false

  /// `tunnel` is shared with every `MachineOperations` whose machines use the same tunnels.
  public init(
    origin: URL,
    fetch: FetchClient,
    store: any OperationStore,
    clock: OperationClock = .continuous,
    ids: @escaping @Sendable () -> UUID = { UUID() },
    trace: @escaping @Sendable (OperationTrace) throws -> Void = { _ in },
    tunnel: TunnelLanes = TunnelLanes(),
  ) throws {
    guard origin.scheme == "http" || origin.scheme == "https", origin.host != nil else { throw OperationError(.invalidInput) }
    link = MachineLink(origin: origin, fetch: fetch, clock: clock, ids: ids, trace: trace)
    self.store = store; self.tunnel = tunnel
  }

  // MARK: Machines

  public func describe(_ machine: String) async throws -> MachineDescription {
    let outcome = await link.send(MachineDescription.self, link.address(machine), correlation: nil, deadline: Self.describeDeadline, limit: 1024 * 1024)
    let description = try outcome.result.get()
    guard description.version == 2, description.limits.isValid,
          description.kinds.allSatisfy({ $0.schemaDialect == "https://json-schema.org/draft/2020-12/schema" }) else { throw OperationError(.unsupportedProtocol) }
    descriptions[machine] = (description, link.clock.now())
    return description
  }

  /// The last description, when it is younger than a third of the machine's lease.
  public func recentDescription(_ machine: String) -> MachineDescription? {
    guard let cached = descriptions[machine], link.clock.now() - cached.at < .milliseconds(cached.description.limits.leaseMs / 3) else { return nil }
    return cached.description
  }

  /// Confirms a leaving machine's settled departure: the machine answers `leaving`.
  public func acknowledgeLeave(_ machine: String) async throws {
    let outcome = await link.send(MachineDescription.self, link.address(machine, query: [.init(name: "leaveAck", value: "true")]), correlation: nil, deadline: Self.describeDeadline, limit: 1024 * 1024)
    switch outcome.result {
    case .success: throw OperationError(.invalidResponse, message: "Machine did not confirm settled departure")
    case let .failure(error) where error.code == .leaving: descriptions[machine] = nil
    case let .failure(error): throw error
    }
  }

  /// Drops what is cached about a machine that left the membership.
  public func forget(_ machine: String) { descriptions[machine] = nil }

  // MARK: Operations

  public func lookup(_ owner: OperationOwner) async throws -> ClientRecord? {
    if let entry = drivers.values.first(where: { $0.owner == owner }) { return await entry.driver.record }
    return try await store.lookup(owner)
  }

  /// The owner's operation: started now when it has none, else the existing one (`invocationConflict` when the machine or
  /// start differ). A fresh start returns once the machine took it, or throws the machine's refusal. `consumer` is the fresh
  /// record's consumer state, durable with its claim.
  public func open(_ owner: OperationOwner, machine: String, start: StartRequest, consumer: JSONValue? = nil) async throws -> Operation {
    guard !closed else { throw OperationError(.requestCancelled) }
    while let pending = opening[owner] { _ = try? await pending.value }
    // A shutdown that ran while this open waited fenced only the claims it saw.
    guard !closed else { throw OperationError(.requestCancelled) }
    let task = try taskScope.run("operation-claim") {
      // Cleared by the task itself, before any waiter resumes, so a waiter never finds a finished task still registered.
      defer { self.opening[owner] = nil }
      return try await self.claim(owner, machine: machine, start: start, consumer: consumer)
    }
    opening[owner] = task
    return try await task.value
  }

  private func claim(_ owner: OperationOwner, machine: String, start: StartRequest, consumer: JSONValue?) async throws -> Operation {
    if let prior = try await store.lookup(owner) {
      guard try prior.machine == machine && prior.start.canonicalData() == start.canonicalData() else { throw OperationError(.invocationConflict, operation: prior.id) }
      return attach(prior, owner: owner)
    }
    let description = try await admissionDescription(machine)
    try admit(start, on: description)
    let lanes = 1 + (description.kinds.first { $0.name == start.kind }?.outputChannels.count ?? 0)
    try await tunnel.reserve(lanes, on: machine)
    var proposed = ClientRecord(id: link.ids(), correlation: link.ids(), machine: machine, start: start, description: description)
    proposed.consumer = consumer
    let claim: OperationClaim
    do {
      claim = try await store.claim(owner, record: proposed)
    } catch {
      tunnel.release(lanes, on: machine)
      throw error
    }
    guard claim.dispatch else {
      tunnel.release(lanes, on: machine)
      return attach(claim.record, owner: owner)
    }
    let operation = register(claim.record, owner: owner, dispatch: true, reserved: lanes)
    try await operation.driver.started()
    return operation
  }

  /// A fresh description for a start, so admission sees the machine as it is now; transient failures are retried within one
  /// describe deadline.
  private func admissionDescription(_ machine: String) async throws -> MachineDescription {
    let end = link.clock.now() + Self.describeDeadline
    var delay = OperationDriver.backoff.first
    while true {
      do { return try await describe(machine) } catch let error as OperationError where disposition(error.code) == .retry && link.clock.now() + delay < end {
        try await link.clock.sleep(delay)
        delay = min(delay * 2, OperationDriver.backoff.last)
      }
    }
  }

  private func admit(_ start: StartRequest, on description: MachineDescription) throws {
    guard description.acceptingStarts else { throw OperationError(.leaving, details: ["started": false]) }
    guard let kind = description.kinds.first(where: { $0.name == start.kind }) else {
      if let refusal = description.availability?[start.kind]?.refusal(kind: start.kind) { throw refusal }
      let message = switch start.kind {
      case "stat.v1", "list.v1", "read.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1": "Machine does not support \(start.kind): agent too old, upgrade"
      default: "Machine does not support \(start.kind)"
      }
      throw OperationError(.unknownKind, message: message, details: ["kind": .string(start.kind)])
    }
    if let refusal = description.availability?[start.kind]?.refusal(kind: start.kind) { throw refusal }
    if let schema = kind.inputSchema.object, schema["additionalProperties"] == .bool(false),
       let properties = schema["properties"]?.object, let input = start.input.object
    {
      let unadvertised = input.keys.filter { properties[$0] == nil }.sorted()
      if !unadvertised.isEmpty {
        throw OperationError(
          .kindUnavailable,
          message: "Machine does not support \(start.kind) with \(unadvertised.joined(separator: ", ")): agent too old, upgrade",
          details: ["kind": .string(start.kind), "reason": "agentTooOld", "started": false, "inputs": .array(unadvertised.map { .string($0) })],
        )
      }
    }
    guard try JSONEncoder().encode(start).count <= description.limits.inputBytes else { throw OperationError(.inputTooLarge) }
  }

  /// Starts a driver for every live record, once, before any caller can open one. A record the store cannot read is set aside
  /// instead, alone: the machine's lease ends its operation there.
  public func resume() async throws -> [ResumedOperation] {
    guard !closed else { throw OperationError(.requestCancelled) }
    var resumed: [ResumedOperation] = []
    // An owner still opening registers its own driver: it alone may send the start.
    let live = try await store.live()
    guard !closed else { throw OperationError(.requestCancelled) }
    for stored in live where opening[stored.owner] == nil {
      guard !closed else { throw OperationError(.requestCancelled) }
      switch stored.record {
      case let .success(record):
        resumed.append(.live(attach(record, owner: stored.owner)))
      case let .failure(damage):
        try await store.setAside(stored.id)
        resumed.append(.setAside(stored.owner, damage))
      }
    }
    return resumed
  }

  /// Sets aside an operation whose record can no longer be kept, say one the store refuses to write: its driver stops without
  /// another write, and the store ends the record. The machine's lease ends the operation there.
  public func setAside(_ operation: Operation) async throws {
    if let entry = drivers.removeValue(forKey: operation.id) {
      await entry.driver.shutdown()
      tunnel.release(entry.lanes, on: entry.machine)
    }
    await endKept(operation.id)
    try await store.setAside(operation.id)
  }

  private func attach(_ record: ClientRecord, owner: OperationOwner) -> Operation {
    if let driver = drivers[record.id]?.driver ?? kept[record.id]?.driver { return Operation(id: record.id, owner: owner, driver: driver, operations: self) }
    let lanes = 1 + record.outputChannels.count
    if record.live { tunnel.hold(lanes, on: record.machine) }
    return register(record, owner: owner, dispatch: false, reserved: record.live ? lanes : 0)
  }

  /// Registers the record's driver, which holds `reserved` tunnel lanes until it ends.
  private func register(_ record: ClientRecord, owner: OperationOwner, dispatch: Bool, reserved lanes: Int) -> Operation {
    let driver = OperationDriver(record: record, dispatch: dispatch, link: link, store: store) { [weak self] id in await self?.ended(id) }
    if record.live {
      drivers[record.id] = Entry(driver: driver, owner: owner, machine: record.machine, lanes: lanes)
    } else {
      tunnel.release(lanes, on: record.machine)
    }
    _ = try? taskScope.run("operation-driver") { await driver.run() }
    return Operation(id: record.id, owner: owner, driver: driver, operations: self)
  }

  private func ended(_ id: UUID) {
    guard let entry = drivers.removeValue(forKey: id) else { return }
    tunnel.release(entry.lanes, on: entry.machine)
  }

  /// Abandons through the operation's current driver, kept by this instance from before the abandon's write until the abandoning
  /// stop it may call for is done, so the driver always has an owner and the record one writer.
  func abandon(_ operation: Operation, _ reason: String, consumer: JSONValue?) async throws {
    let id = operation.id
    guard !closed else { throw OperationError(.requestCancelled, operation: id) }
    let driver = drivers[id]?.driver ?? kept[id]?.driver ?? operation.driver
    kept[id, default: Kept(driver: driver)].abandons += 1
    defer { abandoned(id) }
    // `shutdown` or `setAside` may have ended the driver meanwhile: then nothing is to own a stop.
    guard try await driver.abandon(reason, consumer: consumer), !closed, let held = kept[id], held.driver === driver, held.stop == nil else { return }
    tunnel.hold(1, on: driver.machine)
    do {
      kept[id]?.stop = try taskScope.run("operation-cleanup-stop") {
        await driver.cleanupStop()
        self.stopped(id)
      }
    } catch {
      tunnel.release(1, on: driver.machine)
      throw OperationError(.requestCancelled, operation: id)
    }
  }

  private func abandoned(_ id: UUID) {
    kept[id]?.abandons -= 1
    if let held = kept[id], held.abandons == 0, held.stop == nil { kept[id] = nil }
  }

  private func stopped(_ id: UUID) {
    guard let held = kept[id], held.stop != nil else { return }
    tunnel.release(1, on: held.driver.machine)
    if held.abandons == 0 { kept[id] = nil } else { kept[id]?.stop = nil }
  }

  /// Returns once the kept driver writes nothing more and its stop is over.
  private func endKept(_ id: UUID) async {
    guard let held = kept.removeValue(forKey: id) else { return }
    held.stop?.cancel()
    await held.driver.shutdown()
    await held.stop?.value
    if held.stop != nil { tunnel.release(1, on: held.driver.machine) }
  }

  /// Operations whose drivers are running, for diagnostics and tests.
  public var running: Int { drivers.count }

  /// Returns once no driver of this instance writes the store or talks to a machine any more.
  public func shutdown() async {
    closed = true
    let claims = Array(opening.values)
    for task in claims { task.cancel() }
    for task in claims { _ = try? await task.value }
    let current = drivers
    drivers = [:]
    for entry in current.values {
      await entry.driver.shutdown()
      tunnel.release(entry.lanes, on: entry.machine)
    }
    for id in Array(kept.keys) { await endKept(id) }
    await taskScope.close()
    link.taskScope.cancel()
  }
}
