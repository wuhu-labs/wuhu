#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteRequest
import typealias Serve.Handler

public actor OperationAgent {
  public nonisolated let instance: UUID
  let machine: String
  let kinds: [String: AnyOperationKind]
  let clock: OperationClock
  let limits: OperationLimits
  let receiptRetention: Duration
  let ids: @Sendable () -> UUID
  let authorize: @Sendable (Request, String) async throws -> Void
  let availability: KindAvailabilityProvider?
  var operations: [UUID: OperationState] = [:] { didSet { changed() } }
  /// Everything waiting for the next change to `operations`: a kind's send or read, a held poll.
  private var waiters: [Int: AsyncStream<Void>.Continuation] = [:]
  /// How many waits ever began: a test's evidence that blocked work stays parked.
  private(set) var nextWaiter = 0
  var waiting: Int { waiters.count }
  /// Finished operations dropped before they settled: their operation evidence is gone.
  public private(set) var lostOperations: Set<UUID> = []
  var closed = false
  var running = false
  let starts: AsyncStream<UUID>
  let startQueue: AsyncStream<UUID>.Continuation
  var executions: [UUID: @Sendable (OperationChannels, OperationCancellation) async throws -> JSONValue] = [:]

  public init(
    machine: String,
    kinds: [AnyOperationKind],
    clock: OperationClock = .continuous,
    limits: OperationLimits = .init(),
    receiptRetention: Duration = OperationAgent.receiptRetention,
    instance: UUID = UUID(),
    ids: @escaping @Sendable () -> UUID = { UUID() },
    availability: KindAvailabilityProvider? = nil,
    authorize: @escaping @Sendable (Request, String) async throws -> Void,
  ) throws {
    guard limits.isValid, !machine.isEmpty, receiptRetention > .zero else { throw OperationError(.invalidInput, message: "Invalid machine registry or limits") }
    try Self.validate(descriptors: kinds.map(\.descriptor), limits: limits)
    self.machine = machine; self.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0.descriptor.name, $0) })
    self.clock = clock; self.limits = limits; self.receiptRetention = receiptRetention; self.instance = instance; self.ids = ids; self.authorize = authorize; self.availability = availability
    (starts, startQueue) = AsyncStream.makeStream()
  }

  /// How long a finished operation that has not settled (terminal token and every output acknowledged) is held after its caller's last request. A settled one is dropped at once.
  public static let receiptRetention: Duration = .seconds(60)

  /// The registry checks every agent applies at init: unique nonempty names, the 2020-12 dialect, channel windows and record sizes within `limits`, no channels on bounded-result kinds, the worst-case poll response within the transport frame, and the whole registry within 1 MiB. Composers that serve kinds outside an OperationAgent (ComputerAgent's external kind) run the same checks over their combined registry.
  public static func validate(descriptors: [KindDescriptor], limits: OperationLimits = .init()) throws {
    guard limits.isValid, Set(descriptors.map(\.name)).count == descriptors.count else {
      throw OperationError(.invalidInput, message: "Invalid machine registry or limits")
    }
    let probe = UUID()
    for d in descriptors {
      let all = d.inputChannels + d.outputChannels
      guard !d.name.isEmpty, d.schemaDialect == "https://json-schema.org/draft/2020-12/schema",
            Set(all.map(\.name)).count == all.count,
            all.allSatisfy({ !$0.name.isEmpty && $0.windowBytes > 0 && $0.windowBytes <= limits.bufferBytes
                && $0.maxRecordBytes > 0 && $0.maxRecordBytes <= min($0.windowBytes, limits.pollBytes) }),
            d.deliveryPolicy != .boundedResult || all.isEmpty else { throw OperationError(.unsupportedProtocol) }
      let metadata = OperationSnapshot(
        operation: probe,
        verdict: .init(.completed, result: .null),
        terminalToken: probe,
        finalOffsets: Dictionary(uniqueKeysWithValues: d.outputChannels.map { ($0.name, Offset(rawValue: UInt64.max)) }),
        outputConsumed: false,
        channel: d.outputChannels.max(by: { $0.name.utf8.count < $1.name.utf8.count })?.name,
        from: .zero,
        through: Offset(rawValue: UInt64.max),
        payload: .init(data: Data()),
      )
      let head = try Body.json(metadata, outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).contentLength ?? 0
      let largest = all.map(\.windowBytes).max() ?? 0
      let worst = Int(head) + limits.resultBytes + max(limits.pollBytes, min(largest, limits.filePieceBytes)) * 2 + 32
      let frame = largest > limits.pollBytes ? OperationLimits.maxFileResponseBytes : OperationLimits.responseBytes
      guard worst <= frame else { throw OperationError.capacityExceeded("responseBytes", used: worst, limit: frame) }
    }
    let registry = try JSONEncoder().encode(descriptors).count
    guard registry <= 1024 * 1024 else { throw OperationError.capacityExceeded("registryBytes", used: registry, limit: 1024 * 1024) }
  }

  public nonisolated var handler: Handler { { try await self.handle($0) } }
  public func run() async {
    guard !running && !closed else { return }; running = true
    await withDiscardingTaskGroup { group in
      group.addTask { await self.maintenance() }
      if let changes = availability?.changes {
        group.addTask { for await _ in changes { await self.enforceAvailability() } }
      }
      for await id in starts {
        group.addTask { await self.execute(id) }
      }
      group.cancelAll()
    }
    running = false
  }

  /// What a start of `kind` would reserve, as the kind reports it for this input; nil for a kind this agent does not serve.
  public func reservation(kind: String, input: JSONValue) async throws -> Int? {
    guard let kind = kinds[kind] else { return nil }
    let start = try await kind.prepare(input, limits)
    let d = kind.descriptor
    return (d.inputChannels + d.outputChannels).reduce(0) { $0 + (start.windows[$1.name] ?? $1.windowBytes) }
  }

  public func admissionUsage() -> (receipts: Int, bufferBytes: Int) {
    sweep()
    return (operations.count, operations.values.reduce(0) { $0 + $1.bufferReservation })
  }

  /// Every retained operation, the ones among them a caller may still need (no verdict yet, or a verdict not yet settled), and
  /// the operations dropped before they settled.
  public func inventory() -> (retained: Set<UUID>, unsettled: Set<UUID>, lost: Set<UUID>) {
    sweep()
    return (Set(operations.keys), Set(operations.values.filter { !$0.settled }.map(\.id)), lostOperations)
  }

  public func hasRetainedOperations() -> Bool { sweep(); return !operations.isEmpty }
  public func hasRunningOperations() -> Bool { sweep(); return operations.values.contains { $0.verdict == nil } }
  /// Gives every running operation a stop intent with `reason`; each still ends with a real `stopped` verdict. Retained receipts are untouched.
  public func stopRunning(reason: String) {
    for (id, operation) in operations where operation.verdict == nil { operations[id]?.stopReason = operation.stopReason ?? reason }
  }

  public func inspect(_ operation: UUID) -> OperationSnapshot? { sweep(); return operations[operation]?.snapshot() }

  public func shutdown() { closed = true; startQueue.finish(); for id in operations.keys { operations[id]?.stopReason = "shutdown" } }
  /// Revocation: every running operation whose kind the gate no longer admits gets a stop intent with the gate's reason, so it ends with a real `stopped` verdict.
  func enforceAvailability() async {
    guard let gates = await availability?.current() else { return }
    for (id, operation) in operations where operation.verdict == nil {
      if let reason = gates[operation.kind]?.stopReason { operations[id]?.stopReason = operation.stopReason ?? reason }
    }
  }

  func maintenance() async {
    while !closed && !Task.isCancelled {
      sweep()
      do { try await clock.sleep(.milliseconds(10)) } catch { return }
    }
  }

  /// Drops a finished operation once it settles and every output channel has carried the terminal acknowledgement, and otherwise
  /// `receiptRetention` after its caller's last request. Dropped unsettled, it loses operation evidence.
  func sweep() {
    let now = clock.now()
    for id in operations.keys {
      if operations[id]?.lapsed(now: now) == true { operations[id]?.expire(now: now) }
      guard let op = operations[id], op.finishedAt != nil else { continue }
      let expired = now - op.lastRequest >= receiptRetention
      guard op.released || expired else { continue }
      if !op.settled { lostOperations.insert(id) }
      operations.removeValue(forKey: id)
    }
  }

  func check(_ id: UUID) throws {
    sweep()
    guard let op = operations[id] else { throw OperationError(.unknownOperation) }
    if op.stopReason != nil { throw CancellationError() }
  }

  func kindStop(_ id: UUID, reason: String) throws {
    guard !reason.isEmpty else { throw OperationError(.invalidInput) }
    guard operations[id] != nil else { throw OperationError(.unknownOperation) }
    let chosen = operations[id]?.stopReason ?? reason
    operations[id]?.stopReason = chosen
    throw CancellationError()
  }

  func execute(_ id: UUID) async {
    guard let run = executions.removeValue(forKey: id) else { return }
    let channels = OperationChannels(
      sendImpl: { try await self.send($1, name: $0, id: id) },
      readImpl: { try await self.read($0, bytes: $1, id: id) },
      finishImpl: { try await self.finish($0, id: id) },
      capacityImpl: { try await self.capacity($0, id: id) },
      availableInputImpl: { try await self.availableInput($0, bytes: $1, id: id) },
      publishImpl: { try await self.publish($0, id: id) },
      windowImpl: { await self.window($0, id: id) },
    )
    let cancellation = OperationCancellation(checkImpl: { try await self.check(id) }, stopImpl: { try await self.kindStop(id, reason: $0) }, reasonImpl: { await self.stopReason(id) }, stoppedImpl: { await self.stopped(id) })
    let verdict: Verdict
    do {
      try await cancellation.check()
      let result = try await run(channels, cancellation)
      guard result.jsonString().utf8.count <= limits.resultBytes else { throw OperationError(.resultTooLarge) }
      operations[id]?.expire(now: clock.now())
      let reason = operations[id]?.stopReason
      verdict = .init(reason == nil ? .completed : .stopped, result: result, reason: reason)
    } catch {
      if let reason = operations[id]?.stopReason { verdict = .init(.stopped, reason: reason) }
      else { verdict = .init(.failed, error: error as? OperationError ?? .init(.kindFailed, message: String(describing: error))) }
    }
    operations[id]?.finish(verdict, token: ids(), now: clock.now())
  }

  func send(_ payload: ChannelPayload, name: String, id: UUID) async throws {
    try checkOutput(id)
    guard let channel = operations[id]?.outputs[name] else { throw OperationError(.unknownChannel) }
    try operations[id]?.outputs[name]?.validate(payload)
    var offset = 0
    while offset < payload.count {
      let count = channel.descriptor.unit == .bytes ? min(channel.windowBytes, payload.count - offset) : 1
      let piece = payload.slice(offset ..< offset + count)
      while true {
        try Task.checkCancellation(); try checkOutput(id)
        // A refused append must not write `operations`: the write alone would wake every other blocked producer, and theirs this one.
        guard let channel = operations[id]?.outputs[name] else { throw OperationError(.unknownChannel) }
        if try channel.fits(piece) { _ = try operations[id]?.outputs[name]?.append(piece); break }
        await nextChange()
      }
      offset += count
    }
  }

  func read(_ name: String, bytes: Int, id: UUID) async throws -> ChannelPayload? {
    guard bytes > 0 else { throw OperationError(.invalidInput) }
    while true {
      try Task.checkCancellation(); try check(id)
      guard let state = operations[id]?.inputs[name] else { throw OperationError(.unknownChannel) }
      let value = state.prefix(upTo: min(bytes, state.windowBytes))
      if value.count > 0 {
        try operations[id]?.inputs[name]?.acknowledge(state.floor.advanced(by: value.count)); return value
      }
      if state.payload.count > 0 { throw OperationError(.recordTooLarge) }
      if state.end { return nil }
      await nextChange()
    }
  }

  private func changed() {
    guard !waiters.isEmpty else { return }
    let current = waiters
    waiters = [:]
    for waiter in current.values { waiter.finish() }
  }

  /// Returns at the next change to any operation (or on cancellation). A caller checks its condition, then calls this with no
  /// suspension in between, so no change slips past.
  func nextChange() async {
    let (id, signal) = waiter()
    for await _ in signal {}
    waiters[id] = nil
  }

  /// `nextChange`, or `timeout` on the agent's clock, whichever is first; the clock's failure to sleep is thrown.
  func nextChange(within timeout: Duration) async throws {
    let (id, signal) = waiter()
    defer { waiters[id] = nil }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { for await _ in signal {} }
      group.addTask { [clock] in try await clock.sleep(timeout) }
      try await group.next()
      group.cancelAll()
    }
  }

  private func waiter() -> (Int, AsyncStream<Void>) {
    let id = nextWaiter
    nextWaiter += 1
    let (signal, continuation) = AsyncStream<Void>.makeStream()
    waiters[id] = continuation
    return (id, signal)
  }

  func finish(_ name: String, id: UUID) throws {
    try checkOutput(id)
    guard operations[id]?.outputs[name] != nil else { throw OperationError(.unknownChannel) }
    operations[id]?.outputs[name]?.end = true
  }

  func checkOutput(_ id: UUID) throws {
    sweep()
    guard let op = operations[id] else { throw OperationError(.unknownOperation) }
    if op.verdict == nil && op.stopReason != nil { throw CancellationError() }
  }

  func window(_ name: String, id: UUID) async -> Int {
    operations[id].map { $0.outputs[name]?.windowBytes ?? $0.inputs[name]?.windowBytes ?? 0 } ?? 0
  }

  func capacity(_ name: String, id: UUID) throws -> Int {
    try checkOutput(id)
    guard let channel = operations[id]?.outputs[name], channel.descriptor.unit == .bytes else { throw OperationError(.unknownChannel) }
    return channel.end ? 0 : channel.windowBytes - channel.payload.byteCount
  }

  func availableInput(_ name: String, bytes: Int, id: UUID) throws -> ChannelPayload? {
    try check(id)
    guard bytes > 0, let channel = operations[id]?.inputs[name] else { throw OperationError(.unknownChannel) }
    let value = channel.prefix(upTo: min(bytes, channel.windowBytes))
    if value.count > 0 { try operations[id]?.inputs[name]?.acknowledge(channel.floor.advanced(by: value.count)); return value }
    return channel.end ? nil : value
  }

  func stopReason(_ id: UUID) -> String? { sweep(); return operations[id]?.stopReason }

  func stopped(_ id: UUID) async {
    while !Task.isCancelled, let operation = operations[id], operation.stopReason == nil { await nextChange() }
  }

  func publish(_ verdict: Verdict, id: UUID) throws {
    sweep()
    guard operations[id] != nil else { throw OperationError(.unknownOperation) }
    guard verdict.result?.jsonString().utf8.count ?? 0 <= limits.resultBytes else { throw OperationError(.resultTooLarge) }
    operations[id]?.publish(verdict, token: ids(), now: clock.now())
  }

  func handle(_ request: Request) async throws -> Response {
    var response: Response
    do { response = try await route(request) }
    catch {
      response = try .json(
        ErrorEnvelope(error as? OperationError ?? .init(.invalidInput)),
        status: .init(code: (error as? OperationError)?.statusCode ?? 400),
      )
    }
    response.headers[.init("X-Wuhu-Agent-Instance")!] = instance.uuidString
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.cacheControl] = "no-store"
    return response
  }

  func route(_ request: Request) async throws -> Response {
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"], path[3] == machine else { throw OperationError(.unknownMachine) }
    try await authorize(request, machine)
    sweep()
    if path.count == 4 && request.method == .get {
      let gates = await availability?.describe(linked: kinds.keys)
      return try .json(MachineDescription(
        instance: instance,
        acceptingStarts: !closed,
        limits: limits,
        kinds: kinds.values.map(\.descriptor).sorted { $0.name < $1.name },
        availability: gates,
      ))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post && path.count == 6 {
      guard !closed else { throw OperationError(.leaving) }
      guard operations[id] == nil else { throw OperationError(.operationExists) }
      let start: StartRequest
      do { start = try await request.json(StartRequest.self, upTo: limits.inputBytes) }
      catch FetchError.bodyLimitExceeded { throw OperationError(.inputTooLarge) }
      try await availability?.admit(start.kind)
      guard let kind = kinds[start.kind] else { throw OperationError(.unknownKind) }
      let run: @Sendable (OperationChannels, OperationCancellation) async throws -> JSONValue
      let reserved: [String: Int]
      do { let prepared = try await kind.prepare(start.input, limits); run = prepared.run; reserved = prepared.windows }
      catch let error as OperationError { throw error } catch { throw OperationError(.invalidInput) }
      guard !closed else { throw OperationError(.leaving) }
      guard operations[id] == nil else { throw OperationError(.operationExists) }
      let d = kind.descriptor
      let windows = Dictionary(uniqueKeysWithValues: (d.inputChannels + d.outputChannels).map { channel in
        let window = reserved[channel.name] ?? channel.windowBytes
        precondition(window <= channel.windowBytes && window >= 0, "a kind reserved more than its window")
        return (channel.name, window)
      })
      let reserve = windows.values.reduce(0, +)
      let used = operations.values.reduce(0) { $0 + $1.bufferReservation }
      guard operations.count < limits.receipts else { throw OperationError.capacityExceeded("receipts", used: operations.count, limit: limits.receipts) }
      guard reserve <= limits.bufferBytes - used else { throw OperationError.capacityExceeded("bufferBytes", used: used, limit: limits.bufferBytes, requested: reserve) }
      let now = clock.now()
      operations[id] = .init(
        id: id,
        kind: start.kind,
        inputs: Dictionary(uniqueKeysWithValues: d.inputChannels.map { ($0.name, ChannelState($0, windowBytes: windows[$0.name])) }),
        outputs: Dictionary(uniqueKeysWithValues: d.outputChannels.map { ($0.name, ChannelState($0, windowBytes: windows[$0.name])) }),
        leaseDeadline: now + .milliseconds(limits.leaseMs),
        lastRequest: now,
      )
      executions[id] = run
      // A gate change between admission and insertion: its sweep may have run before this operation existed.
      // Re-check while the operation is inserted but not yet runnable, so a revoked kind never runs its effect.
      if availability?.changes != nil { await enforceAvailability() }
      guard case .enqueued = startQueue.yield(id) else { operations.removeValue(forKey: id); executions.removeValue(forKey: id); throw OperationError(.leaving) }
      guard let created = operations[id] else { throw OperationError(.unknownOperation) }
      return try .json(created.snapshot(), status: .created)
    }
    guard operations[id] != nil else { throw OperationError(.unknownOperation) }
    if request.method == .get && path.count == 6 {
      let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard Set(items.map(\.name)).count == items.count else { throw OperationError(.invalidInput) }
      let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
      let channel = q["channel"]
      let hold = q["holdMs"].flatMap(Int.init) ?? (q["holdMs"] == nil ? 0 : -1)
      let limit = q["limit"].flatMap(Int.init) ?? (q["limit"] == nil ? limits.pollBytes : -1)
      // A poll without a channel is the whole operation: a file operation's control poll asks for a piece. With a channel, the
      // channel's window bounds it.
      let maxPoll = if let channel, let window = operations[id]?.outputs[channel]?.descriptor.windowBytes {
        max(limits.pollBytes, min(window, limits.filePieceBytes))
      } else {
        max(limits.pollBytes, limits.filePieceBytes)
      }
      guard hold >= 0 && hold <= limits.pollHoldMs, limit > 0, limit <= maxPoll else { throw OperationError(.invalidInput) }
      if let channel {
        guard operations[id]?.outputs[channel] != nil else { throw OperationError(.unknownChannel) }
        guard let text = q["after"], text.allSatisfy({ $0.isASCII && $0.isNumber }), let after = UInt64(text) else { throw OperationError(.invalidOffset) }
        try operations[id]?.outputs[channel]?.acknowledge(.init(rawValue: after))
      }
      if let token = q["terminalAck"] {
        guard UUID(uuidString: token) == operations[id]?.terminalToken, operations[id]?.verdict != nil else { throw OperationError(.invalidInput) }
        operations[id]?.terminalAcknowledged = true
        if let channel { operations[id]?.terminalAcknowledgedChannels.insert(channel) }
      }
      operations[id]?.renew(now: clock.now(), lease: .milliseconds(limits.leaseMs))
      let deadline = clock.now() + .milliseconds(hold)
      while true {
        guard let s = operations[id]?.snapshot(channel: channel, limit: limit) else { throw OperationError(.unknownOperation) }
        let now = clock.now()
        if s.verdict != nil || (s.payload?.count ?? 0) > 0 || s.channelEnd || now >= deadline {
          let response = try Response.json(s, outputFormatting: [.sortedKeys, .withoutEscapingSlashes])
          // A file piece rides base64 inside the snapshot: the answer bound follows what the caller asked for.
          let frame = OperationLimits.answerBytes(for: limit)
          guard (response.body.contentLength ?? 0) <= frame else { throw OperationError(.resultTooLarge) }
          return response
        }
        try await nextChange(within: deadline - now); try Task.checkCancellation()
      }
    }
    if request.method == .put && path.count == 7 && path[6] == "stop" {
      let stop = try await request.json(StopRequest.self, upTo: 1024)
      guard let current = operations[id] else { throw OperationError(.unknownOperation) }
      if current.verdict == nil { operations[id]?.stopReason = current.stopReason ?? stop.reason }
      operations[id]?.renew(now: clock.now(), lease: .milliseconds(limits.leaseMs))
      return try .json(operations[id]!.snapshot())
    }
    if request.method == .put && path.count == 8 && path[6] == "inputs" {
      guard operations[id]?.verdict == nil && operations[id]?.stopReason == nil else { throw OperationError(.operationEnded) }
      guard operations[id]?.inputs[path[7]] != nil else { throw OperationError(.unknownChannel) }
      let write: WriteRequest
      do { write = try await request.json(WriteRequest.self, upTo: 2 * limits.filePieceBytes + limits.inputBytes) }
      catch FetchError.bodyLimitExceeded { throw OperationError(.inputTooLarge) }
      guard operations[id]?.verdict == nil && operations[id]?.stopReason == nil else { throw OperationError(.operationEnded) }
      guard operations[id]?.inputs[path[7]] != nil else { throw OperationError(.unknownChannel) }
      let receipt = try operations[id]!.inputs[path[7]]!.write(write)
      operations[id]?.renew(now: clock.now(), lease: .milliseconds(limits.leaseMs))
      return try .json(receipt)
    }
    throw OperationError(.invalidInput)
  }
}
