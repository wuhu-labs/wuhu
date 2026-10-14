#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.ErrorEnvelope
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
  let ids: @Sendable () -> UUID
  let authorize: @Sendable (Request, String) async throws -> Void
  var operations: [UUID: OperationState] = [:]
  var leaving = false
  var pendingDeparture: Set<UUID> = []
  var departureEvidenceLost = false
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
    instance: UUID = UUID(),
    ids: @escaping @Sendable () -> UUID = { UUID() },
    authorize: @escaping @Sendable (Request, String) async throws -> Void,
  ) throws {
    guard limits.isValid, !machine.isEmpty, Set(kinds.map { $0.descriptor.name }).count == kinds.count else {
      throw OperationError(.invalidInput, message: "Invalid machine registry or limits")
    }
    for kind in kinds {
      let d = kind.descriptor; let all = d.inputChannels + d.outputChannels
      guard !d.name.isEmpty, d.schemaDialect == "https://json-schema.org/draft/2020-12/schema",
            Set(all.map(\.name)).count == all.count,
            all.allSatisfy({ !$0.name.isEmpty && $0.windowBytes > 0 && $0.windowBytes <= limits.bufferBytes
                && $0.maxRecordBytes > 0 && $0.maxRecordBytes <= min($0.windowBytes, limits.pollBytes) }),
            d.deliveryPolicy != .boundedResult || all.isEmpty else { throw OperationError(.unsupportedProtocol) }
      let metadata = OperationSnapshot(
        operation: instance,
        verdict: .init(.completed, result: .null),
        terminalToken: instance,
        finalOffsets: Dictionary(uniqueKeysWithValues: d.outputChannels.map { ($0.name, Offset(rawValue: UInt64.max)) }),
        outputConsumed: false,
        channel: d.outputChannels.max(by: { $0.name.utf8.count < $1.name.utf8.count })?.name,
        from: .zero,
        through: Offset(rawValue: UInt64.max),
        payload: .init(data: Data()),
      )
      let head = try Body.json(metadata, outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).contentLength ?? 0
      guard head + Int64(limits.resultBytes) + Int64(limits.pollBytes) * 2 + 32 <= OperationLimits.responseBytes else { throw OperationError(.capacityExceeded) }
    }
    guard try JSONEncoder().encode(kinds.map(\.descriptor)).count <= 1024 * 1024 else { throw OperationError(.capacityExceeded) }
    self.machine = machine; self.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0.descriptor.name, $0) })
    self.clock = clock; self.limits = limits; self.instance = instance; self.ids = ids; self.authorize = authorize
    (starts, startQueue) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(limits.activeOperations))
  }

  public nonisolated var handler: Handler { { try await self.handle($0) } }
  public func run() async {
    guard !running && !closed else { return }; running = true
    await withDiscardingTaskGroup { group in
      group.addTask { await self.maintenance() }
      for await id in starts {
        group.addTask { await self.execute(id) }
      }
      group.cancelAll()
    }
    running = false
  }

  public func admissionUsage() -> (active: Int, receipts: Int, bufferBytes: Int) {
    sweep()
    return (operations.values.filter { $0.verdict == nil }.count, operations.count, operations.values.reduce(0) { $0 + $1.bufferReservation })
  }

  public func departureSettled() -> Bool {
    sweep()
    return leaving && pendingDeparture.isEmpty && !departureEvidenceLost
  }

  public func hasRetainedOperations() -> Bool { sweep(); return !operations.isEmpty }
  public func inspect(_ operation: UUID) -> OperationSnapshot? { sweep(); return operations[operation]?.snapshot() }

  public func shutdown() { closed = true; startQueue.finish(); for id in operations.keys { operations[id]?.stopReason = "shutdown" } }
  public func leave() {
    leaving = true
    pendingDeparture.formUnion(operations.values.filter { !$0.departureSettled }.map(\.id))
    for (id, operation) in operations where operation.verdict == nil { operations[id]?.stopReason = operation.stopReason ?? "leaving" }
  }

  func maintenance() async {
    while !closed && !Task.isCancelled {
      sweep()
      do { try await clock.sleep(.milliseconds(10)) } catch { return }
    }
  }

  func sweep() {
    let now = clock.now()
    for id in operations.keys {
      operations[id]?.expire(now: now)
      if let op = operations[id], let finished = op.finishedAt {
        if now - op.lastRequest >= .milliseconds(limits.leaseMs) {
          for c in op.outputs.keys { operations[id]?.outputs[c]?.expireRetention() }
        }
        if now - finished >= .milliseconds(limits.receiptMs) {
          if !op.departureSettled { departureEvidenceLost = true }
          operations.removeValue(forKey: id)
        }
      }
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
    )
    let cancellation = OperationCancellation(checkImpl: { try await self.check(id) }, stopImpl: { try await self.kindStop(id, reason: $0) }, reasonImpl: { await self.stopReason(id) })
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
    guard let descriptor = operations[id]?.outputs[name]?.descriptor else { throw OperationError(.unknownChannel) }
    try operations[id]?.outputs[name]?.validate(payload)
    var offset = 0
    while offset < payload.count {
      let count = descriptor.unit == .bytes ? min(descriptor.windowBytes, payload.count - offset) : 1
      let piece = payload.slice(offset ..< offset + count)
      while true {
        try Task.checkCancellation(); try checkOutput(id)
        if try operations[id]?.outputs[name]?.append(piece) == true { break }
        try await clock.sleep(.milliseconds(10))
      }
      offset += count
    }
  }

  func read(_ name: String, bytes: Int, id: UUID) async throws -> ChannelPayload? {
    guard bytes > 0 else { throw OperationError(.invalidInput) }
    while true {
      try Task.checkCancellation(); try check(id)
      guard let state = operations[id]?.inputs[name] else { throw OperationError(.unknownChannel) }
      let value = state.prefix(upTo: min(bytes, limits.pollBytes))
      if value.count > 0 {
        try operations[id]?.inputs[name]?.acknowledge(state.floor.advanced(by: value.count)); return value
      }
      if state.payload.count > 0 { throw OperationError(.recordTooLarge) }
      if state.end { return nil }
      try await clock.sleep(.milliseconds(10))
    }
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

  func capacity(_ name: String, id: UUID) throws -> Int {
    try checkOutput(id)
    guard let channel = operations[id]?.outputs[name], channel.descriptor.unit == .bytes else { throw OperationError(.unknownChannel) }
    return channel.end ? 0 : channel.descriptor.windowBytes - channel.payload.byteCount
  }

  func availableInput(_ name: String, bytes: Int, id: UUID) throws -> ChannelPayload? {
    try check(id)
    guard bytes > 0, let channel = operations[id]?.inputs[name] else { throw OperationError(.unknownChannel) }
    let value = channel.prefix(upTo: min(bytes, limits.pollBytes))
    if value.count > 0 { try operations[id]?.inputs[name]?.acknowledge(channel.floor.advanced(by: value.count)); return value }
    return channel.end ? nil : value
  }

  func stopReason(_ id: UUID) -> String? { sweep(); return operations[id]?.stopReason }

  func publish(_ verdict: Verdict, id: UUID) throws {
    sweep()
    guard operations[id] != nil else { throw OperationError(.unknownOperation) }
    guard verdict.result?.jsonString().utf8.count ?? 0 <= limits.resultBytes else { throw OperationError(.resultTooLarge) }
    operations[id]?.publish(verdict, token: ids(), now: clock.now())
  }

  func handle(_ request: Request) async throws -> Response {
    var response: Response
    do { response = try await route(request) }
    catch { response = try .json(
      ErrorEnvelope(error as? OperationError ?? .init(.invalidInput)),
      status: .init(code: (error as? OperationError)?.statusCode ?? 400),
    ) }
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
      if leaving && pendingDeparture.isEmpty && !departureEvidenceLost { throw OperationError(.leaving) }
      return try .json(MachineDescription(
        instance: instance,
        acceptingStarts: !leaving && !closed,
        limits: limits,
        kinds: kinds.values.map(\.descriptor).sorted { $0.name < $1.name },
      ))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post && path.count == 6 {
      guard !leaving && !closed else { throw OperationError(.leaving) }
      guard operations[id] == nil else { throw OperationError(.operationExists) }
      let start: StartRequest
      do { start = try await request.json(StartRequest.self, upTo: limits.inputBytes) }
      catch FetchError.bodyLimitExceeded { throw OperationError(.inputTooLarge) }
      guard let kind = kinds[start.kind] else { throw OperationError(.unknownKind) }
      let run: @Sendable (OperationChannels, OperationCancellation) async throws -> JSONValue
      do { run = try kind.prepare(start.input) } catch let error as OperationError { throw error } catch { throw OperationError(.invalidInput) }
      guard !leaving && !closed else { throw OperationError(.leaving) }
      guard operations[id] == nil else { throw OperationError(.operationExists) }
      let d = kind.descriptor
      let reserve = (d.inputChannels + d.outputChannels).reduce(0) { $0 + $1.windowBytes }
      let used = operations.values.reduce(0) { $0 + $1.bufferReservation }
      guard operations.count < limits.receipts, operations.values.filter({ $0.verdict == nil }).count < limits.activeOperations,
            reserve <= limits.bufferBytes - used else { throw OperationError(.capacityExceeded) }
      let now = clock.now()
      operations[id] = .init(
        id: id,
        inputs: Dictionary(uniqueKeysWithValues: d.inputChannels.map { ($0.name, ChannelState($0)) }),
        outputs: Dictionary(uniqueKeysWithValues: d.outputChannels.map { ($0.name, ChannelState($0)) }),
        leaseDeadline: now + .milliseconds(limits.leaseMs),
        lastRequest: now,
      )
      executions[id] = run
      guard case .enqueued = startQueue.yield(id) else { operations.removeValue(forKey: id); executions.removeValue(forKey: id); throw OperationError(.capacityExceeded) }
      return try .json(operations[id]!.snapshot(), status: .created)
    }
    guard operations[id] != nil else { throw OperationError(.unknownOperation) }
    if request.method == .get && path.count == 6 {
      let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard Set(items.map(\.name)).count == items.count else { throw OperationError(.invalidInput) }
      let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
      let channel = q["channel"]
      let hold = q["holdMs"].flatMap(Int.init) ?? (q["holdMs"] == nil ? 0 : -1)
      let limit = q["limit"].flatMap(Int.init) ?? (q["limit"] == nil ? limits.pollBytes : -1)
      guard hold >= 0 && hold <= limits.pollHoldMs, limit > 0 && limit <= limits.pollBytes else { throw OperationError(.invalidInput) }
      if let channel {
        guard operations[id]?.outputs[channel] != nil else { throw OperationError(.unknownChannel) }
        guard let text = q["after"], text.allSatisfy({ $0.isASCII && $0.isNumber }), let after = UInt64(text) else { throw OperationError(.invalidOffset) }
        try operations[id]?.outputs[channel]?.acknowledge(.init(rawValue: after))
      }
      if let token = q["terminalAck"] {
        guard UUID(uuidString: token) == operations[id]?.terminalToken, operations[id]?.verdict != nil else { throw OperationError(.invalidInput) }
        operations[id]?.terminalAcknowledged = true
      }
      if operations[id]?.departureSettled == true { pendingDeparture.remove(id) }
      operations[id]?.renew(now: clock.now(), lease: .milliseconds(limits.leaseMs))
      let deadline = clock.now() + .milliseconds(hold)
      while true {
        let s = operations[id]!.snapshot(channel: channel, limit: limit)
        if s.verdict != nil || (s.payload?.count ?? 0) > 0 || s.channelEnd || clock.now() >= deadline {
          let response = try Response.json(s, outputFormatting: [.sortedKeys, .withoutEscapingSlashes])
          guard (response.body.contentLength ?? 0) <= OperationLimits.responseBytes else { throw OperationError(.resultTooLarge) }
          return response
        }
        try await clock.sleep(.milliseconds(10)); try Task.checkCancellation()
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
      do { write = try await request.json(WriteRequest.self, upTo: limits.inputBytes) }
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
