import ServerTelemetry
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
import struct OperationProtocol.OperationTrace
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import struct OperationProtocol.WriteReceipt
import struct OperationProtocol.WriteRequest

public actor OperationClient {
  let origin: URL
  let clock: OperationClock
  let wallNow: @Sendable () -> Date
  var answerDates: [String: Date] = [:]
  var leftDates: [String: Date] = [:]
  let store: any OperationStore
  let ledger: ExchangeLedger
  let ids: @Sendable () -> UUID
  let requestTimeout: Duration
  let pollTimeout: Duration
  var descriptions: [String: MachineDescription] = [:]
  var presence: [String: Duration] = [:]
  var detached: Set<String> = []
  var lastAnswer: [UUID: Duration] = [:]
  var callerDeadline: [UUID: Duration] = [:]
  var dispatching: Set<UUID> = []
  var telemetrySpans: [UUID: ServerSpan] = [:]
  var busy: Set<String> = []
  var outputReservations: [UUID: Int] = [:]
  public init(
    origin: URL,
    fetch: FetchClient,
    clock: OperationClock = .continuous,
    store: any OperationStore,
    requestTimeout: Duration = .seconds(5),
    pollTimeout: Duration = .seconds(25),
    maxExchanges: Int = 32,
    ids: @escaping @Sendable () -> UUID = { UUID() },
    wallNow: @escaping @Sendable () -> Date = { Date() },
    abort: @escaping @Sendable (UUID) -> Void,
    trace: @escaping @Sendable (OperationTrace) throws -> Void,
  ) throws {
    guard origin.scheme == "http" || origin.scheme == "https", origin.host != nil,
          requestTimeout > .zero, pollTimeout > .zero, maxExchanges > 0 else { throw OperationError(.invalidInput) }
    self.origin = origin; self.clock = clock; self.wallNow = wallNow; self.store = store; self.ids = ids
    self.requestTimeout = requestTimeout; self.pollTimeout = pollTimeout
    ledger = ExchangeLedger(fetch: fetch, clock: clock, capacity: maxExchanges, abort: abort, trace: trace)
  }

  public func shutdown() async {
    for span in telemetrySpans.values { span.finish([.version: "v2", .outcome: "cancelled"]) }
    telemetrySpans.removeAll()
    await ledger.shutdown()
  }

  func address(_ machine: String, operation: UUID? = nil, suffix: String = "") -> URL {
    var url = origin.appendingPathComponent("machine/v2/machines").appendingPathComponent(machine)
    if let operation { url = url.appendingPathComponent("operations").appendingPathComponent(operation.uuidString) }
    return suffix.isEmpty ? url : url.appendingPathComponent(suffix)
  }

  func request<T: Decodable & Sendable>(
    _ type: T.Type,
    url: URL,
    method: Fetch.Method = .get,
    body: Body? = nil,
    record: ClientRecord? = nil,
    poll: Bool = false,
    silenceBound: Bool = true,
    validate: (T) async throws -> T = { $0 },
  ) async throws -> T {
    let requestID = ids()
    var req = Request(url: url, method: method, body: body)
    req.headers["X-Wuhu-Request-ID"] = requestID.uuidString
    req.headers["X-Wuhu-Correlation-ID"] = (record?.correlation ?? requestID).uuidString
    var timeout = poll ? pollTimeout : requestTimeout
    if let record, let deadline = callerDeadline[record.id] { timeout = min(timeout, max(.zero, deadline - clock.now())) }
    if silenceBound, let record, record.snapshot?.verdict == nil, let seen = lastAnswer[record.id] {
      timeout = min(timeout, max(.zero, seen + .milliseconds(record.description.limits.leaseMs) - clock.now()))
    }
    let began = clock.now()
    let deadline = began + timeout
    do {
      let data = try await ledger.exchange(req, id: requestID, timeout: timeout, limit: record == nil ? 1024 * 1024 : OperationLimits.responseBytes)
      do {
        let value: T
        do { value = try JSONDecoder().decode(type, from: data) } catch { throw OperationError(.invalidResponse) }
        guard clock.now() < deadline else { throw OperationError(.requestDeadline) }
        let validated = try await validate(value)
        try await ledger.record(req, id: requestID, began: began, event: .complete)
        return validated
      } catch {
        let code = (error as? OperationError)?.code ?? .storeUnavailable
        try await ledger.record(req, id: requestID, began: began, event: .failure, error: code)
        throw error
      }
    } catch {
      if let record, let deadline = callerDeadline[record.id], clock.now() >= deadline {
        try await abandon(record, reason: "callerDeadline")
        throw OperationError(.callerDeadline, operation: record.id, details: ["outcome": "pending"])
      }
      throw error
    }
  }

  public func describe(_ machine: String) async throws -> MachineDescription {
    do {
      let d = try await request(MachineDescription.self, url: address(machine))
      guard d.version == 2 && d.limits.isValid,
            d.kinds.allSatisfy({ $0.schemaDialect == "https://json-schema.org/draft/2020-12/schema" }) else { throw OperationError(.unsupportedProtocol) }
      guard descriptions[machine] != nil || descriptions.count < 4096 else { throw OperationError(.capacityExceeded) }
      descriptions[machine] = d; presence[machine] = clock.now(); answerDates[machine] = wallNow(); detached.remove(machine); return d
    } catch let error as OperationError {
      if error.code == .leaving { detached.insert(machine); leftDates[machine] = wallNow() }; throw error
    }
  }

  public func acknowledgeLeave(_ machine: String) async throws {
    var components = URLComponents(url: address(machine), resolvingAgainstBaseURL: false)!
    components.queryItems = [.init(name: "leaveAck", value: "true")]
    do {
      _ = try await request(MachineDescription.self, url: components.url!)
      throw OperationError(.invalidResponse, message: "Machine did not confirm settled departure")
    } catch let error as OperationError where error.code == .leaving {
      detached.insert(machine); leftDates[machine] = wallNow()
    }
  }

  public func start(
    _ machine: String,
    request start: StartRequest,
    owner: OperationOwner,
    timeout: Duration? = nil,
    onClaim: @Sendable (UUID) -> Void = { _ in },
  ) async throws -> UUID {
    if let timeout, timeout <= .zero { throw OperationError(.invalidInput) }
    if let prior = try await store.lookup(owner) {
      guard try prior.machine == machine && prior.start.canonicalData() == start.canonicalData() else { throw OperationError(.invocationConflict, operation: prior.id) }
      onClaim(prior.id)
      _ = try await reconcile(prior.id); return prior.id
    }
    if let prior = descriptions[machine], let seen = presence[machine], !detached.contains(machine),
       clock.now() - seen >= .milliseconds(prior.limits.leaseMs) { _ = try await describe(machine) }
    guard let d = descriptions[machine], let seen = presence[machine], !detached.contains(machine),
          clock.now() - seen < .milliseconds(d.limits.leaseMs)
    else {
      let detached = detached.contains(machine)
      throw OperationError(.machineUnavailable, details: [
        "state": .string(detached ? "detached" : "lost"),
        "started": false,
        detached ? "leftAt" : "silentSince": .number((detached ? leftDates[machine] : answerDates[machine])?.timeIntervalSince1970 ?? wallNow().timeIntervalSince1970),
      ])
    }
    guard d.acceptingStarts else { throw OperationError(.leaving, details: ["started": false]) }
    guard d.kinds.contains(where: { $0.name == start.kind }) || d.availability?[start.kind] != nil else {
      let message: String
      switch start.kind {
      case "stat.v1", "list.v1", "read.v1", "write.v1", "mkdir.v1", "remove.v1", "move.v1":
        message = "Machine does not support \(start.kind): agent too old, upgrade"
      default: message = "Machine does not support \(start.kind)"
      }
      throw OperationError(.unknownKind, message: message, details: ["kind": .string(start.kind)])
    }
    if let unadvertised = Self.unadvertisedInputs(start, in: d), !unadvertised.isEmpty {
      throw OperationError(
        .kindUnavailable,
        message: "Machine does not support \(start.kind) with \(unadvertised.joined(separator: ", ")): agent too old, upgrade",
        details: ["kind": .string(start.kind), "reason": "agentTooOld", "started": false, "inputs": .array(unadvertised.map { .string($0) })],
      )
    }
    let body = try Body.json(start)
    guard (body.contentLength ?? 0) <= d.limits.inputBytes else { throw OperationError(.inputTooLarge) }
    var proposed = ClientRecord(id: ids(), correlation: ids(), machine: machine, start: start, description: d)
    if let timeout {
      let components = timeout.components
      guard components.seconds < Int64(Int.max / 1000) else { throw OperationError(.invalidInput) }
      proposed.callerRemainingMs = max(1, Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000))
    }
    let claim = try await store.claim(owner, record: proposed)
    let r = claim.record
    if ServerTracing.enabled, telemetrySpans[r.id] == nil, r.snapshot?.verdict == nil, telemetrySpans.count < 1024 {
      telemetrySpans[r.id] = ServerSpan(.machine)
    }
    onClaim(r.id)
    if lastAnswer[r.id] == nil { lastAnswer[r.id] = clock.now() }
    if let timeout, claim.dispatch { callerDeadline[r.id] = clock.now() + timeout }
    if claim.dispatch {
      dispatching.insert(r.id); defer { dispatching.remove(r.id) }
      do {
        _ = try await request(OperationSnapshot.self, url: address(machine, operation: r.id), method: .post, body: try await oneShotStart(body), record: r) { snapshot in
          guard snapshot.channel == nil else { throw OperationError(.invalidResponse) }
          return try await self.commit(snapshot, record: r)
        }
      } catch let error as OperationError {
        dispatching.remove(r.id)
        if let deadline = callerDeadline[r.id], clock.now() >= deadline { try await abandon(r, reason: "callerDeadline"); throw OperationError(.callerDeadline, operation: r.id, details: ["outcome": "pending"]) }
        if error.code != .requestDeadline && error.code != .transport { throw error }
        _ = try? await poll(r.id)
      }
    } else { _ = try await poll(r.id) }
    return r.id
  }

  func oneShotStart(_ body: Body) async throws -> Body {
    let bytes = try await body.data()
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1))
    continuation.yield(bytes); continuation.finish()
    return .stream(length: Int64(bytes.count), contentType: "application/json", stream)
  }

  func active(_ id: UUID, allowStopped: Bool = false) async throws -> ClientRecord {
    let r = try await store.read(id)
    if let error = r.unknown { throw error }
    if r.snapshot?.verdict != nil { return r }
    let now = clock.now()
    if callerDeadline[id] == nil, r.stopReason == nil, let remaining = r.callerRemainingMs {
      callerDeadline[id] = now + .milliseconds(remaining)
    }
    let seen = lastAnswer[id] ?? now
    lastAnswer[id] = seen
    if now - seen >= .milliseconds(r.description.limits.leaseMs) {
      let error = OperationError(.unknownOperation, operation: id, details: ["outcome": "unknown", "reason": "leaseSilence"])
      _ = try await store.transaction(id) { $0.unknown = error; $0.stopReason = "leaseSilence" }
      Task { _ = try? await self.sendStop(id, reason: "leaseSilence", bestEffort: true) }; throw error
    }
    if r.stopReason == nil, let deadline = callerDeadline[id], now >= deadline {
      try await abandon(r, reason: "callerDeadline")
      throw OperationError(.callerDeadline, operation: id, details: ["outcome": "pending"])
    }
    if !allowStopped && r.stopReason != nil { throw OperationError(.operationEnded, operation: id) }
    return r
  }

  func abandon(_ r: ClientRecord, reason: String) async throws {
    _ = try await store.transaction(r.id) { $0.stopReason = reason; $0.callerRemainingMs = 0 }
    callerDeadline.removeValue(forKey: r.id)
    Task { _ = try? await self.stop(r.id, reason: reason) }
  }

  public func reconcile(_ id: UUID, holdMs: Int = 0) async throws -> OperationSnapshot {
    let record = try await active(id, allowStopped: true)
    if let reason = record.stopReason { return try await stop(id, reason: reason) }
    do { return try await poll(id, holdMs: holdMs) }
    catch let error as OperationError where error.code == .operationEnded {
      let current = try await active(id, allowStopped: true)
      if let reason = current.stopReason { return try await stop(id, reason: reason) }
      throw error
    }
  }

  /// Keeps abandoned stop intent deliverable after local silence became unknown, without renewing a caller or replaying start.
  public func reconcileAbandoned(_ id: UUID) async throws -> OperationSnapshot {
    let record = try await store.read(id)
    guard let reason = record.stopReason else { throw OperationError(.invalidInput, operation: id) }
    return try await sendStop(id, reason: reason, bestEffort: record.unknown != nil)
  }

  public func poll(_ id: UUID, channel: String? = nil, holdMs: Int = 0, terminalAck: Bool = false) async throws -> OperationSnapshot {
    let key = "\(id)/output/\(channel ?? "state")"
    guard busy.insert(key).inserted else { throw OperationError(.capacityExceeded) }; defer { busy.remove(key) }
    let r = try await active(id)
    var reservation = 0
    if let channel {
      guard let descriptor = r.description.kinds.first(where: { $0.name == r.start.kind })?.outputChannels.first(where: { $0.name == channel }) else { throw OperationError(.unknownChannel) }
      let final = r.snapshot?.verdict == nil ? nil : r.snapshot?.finalOffsets[channel]
      reservation = final.map { $0 <= (r.committed[channel] ?? .zero) } == true ? 0 : min(r.description.limits.pollBytes, descriptor.windowBytes)
      while true {
        let current = try await active(id)
        let retained = current.output.values.flatMap { $0 }.reduce(0) { $0 + $1.byteCount }
        if retained + (outputReservations[id] ?? 0) + reservation <= current.outputCapacity { break }
        try await clock.sleep(.milliseconds(10))
        try Task.checkCancellation()
      }
      outputReservations[id, default: 0] += reservation
    }
    defer { if reservation > 0 { outputReservations[id, default: 0] -= reservation; if outputReservations[id] == 0 { outputReservations.removeValue(forKey: id) } } }
    guard holdMs >= 0 && holdMs <= r.description.limits.pollHoldMs else { throw OperationError(.invalidInput) }
    var items = [URLQueryItem(name: "holdMs", value: String(holdMs))]
    if let channel {
      guard r.description.kinds.first(where: { $0.name == r.start.kind })?.outputChannels.contains(where: { $0.name == channel }) == true else { throw OperationError(.unknownChannel) }
      items += [.init(name: "channel", value: channel), .init(name: "after", value: String((r.committed[channel] ?? .zero).rawValue))]
    }
    if terminalAck, let token = r.snapshot?.terminalToken { items.append(.init(name: "terminalAck", value: token.uuidString)) }
    var components = URLComponents(url: address(r.machine, operation: id), resolvingAgainstBaseURL: false)!
    components.queryItems = items
    let dispatchInFlight = dispatching.contains(id)
    do {
      return try await request(OperationSnapshot.self, url: components.url!, record: r, poll: true) { s in
        guard s.channel == channel else { throw OperationError(.invalidResponse) }
        return try await self.commit(s, record: r)
      }
    } catch let error as OperationError {
      if error.code == .unknownOperation { try await saveUnknown(error, record: r, dispatchInFlight: dispatchInFlight) }
      if error.code == .requestDeadline || error.code == .transport { _ = try await active(id) }
      throw error
    }
  }

  func saveUnknown(_ error: OperationError, record: ClientRecord, dispatchInFlight: Bool) async throws {
    guard !dispatchInFlight else { return }
    _ = try await store.transaction(record.id) { current in
      if current.snapshot?.verdict == nil, (current.evidenceGeneration ?? 0) == (record.evidenceGeneration ?? 0) { current.unknown = error }
    }
  }

  func commit(_ s: OperationSnapshot, record r: ClientRecord) async throws -> OperationSnapshot {
    guard s.operation == r.id, (s.verdict == nil) == (s.terminalToken == nil) else { throw OperationError(.invalidResponse) }
    guard (s.verdict?.result?.jsonString().utf8.count ?? 0) <= r.description.limits.resultBytes else { throw OperationError(.resultTooLarge) }
    let updated = try await store.transaction(r.id) { value in
      if value.snapshot?.verdict != nil && s.verdict == nil { return }
      if let existing = value.snapshot?.verdict, s.verdict != existing { throw OperationError(.invalidResponse) }
      if let channel = s.channel {
        guard let from = s.from, let through = s.through, let payload = s.payload,
              from == (value.committed[channel] ?? .zero), try from.advanced(by: payload.count) == through else { throw OperationError(.invalidResponse) }
        guard let descriptor = r.description.kinds.first(where: { $0.name == r.start.kind })?.outputChannels.first(where: { $0.name == channel }),
              (descriptor.unit == .bytes && payload.data != nil && payload.records == nil)
              || (descriptor.unit == .records && payload.records != nil && payload.data == nil),
              payload.byteCount <= r.description.limits.pollBytes,
              payload.records?.allSatisfy({ $0.jsonString().utf8.count <= descriptor.maxRecordBytes }) ?? true else { throw OperationError(.invalidResponse) }
        let buffered = value.output.values.flatMap { $0 }.reduce(0) { $0 + $1.byteCount }
        guard buffered + payload.byteCount <= r.outputCapacity else { throw OperationError(.capacityExceeded) }
        if payload.count > 0 { value.output[channel, default: []].append(payload) }
        value.committed[channel] = through
      }
      value.snapshot = s
      try value.markEvidence()
      if s.verdict != nil || value.unknown?.details != ["outcome": "unknown", "reason": "leaseSilence"] { value.unknown = nil }
    }
    if let known = updated.snapshot, known.verdict != nil && s.verdict == nil { return known }
    if let verdict = s.verdict {
      if let span = telemetrySpans.removeValue(forKey: r.id) {
        var attributes: [SpanAttribute: String] = [.machine: r.machine, .version: "v2", .kind: r.start.kind, .verdict: verdict.tag.rawValue, .outcome: verdict.tag == .completed ? "ok" : "error"]
        attributes[.errorCode] = verdict.error?.code.rawValue
        span.finish(attributes)
      }
      callerDeadline.removeValue(forKey: r.id)
      _ = try await store.transaction(r.id) { $0.callerRemainingMs = nil }
    } else if let deadline = callerDeadline[r.id] {
      let remaining = max(.zero, deadline - clock.now()).components
      let ms = max(0, Int(remaining.seconds) * 1000 + Int(remaining.attoseconds / 1_000_000_000_000_000))
      _ = try await store.transaction(r.id) { $0.callerRemainingMs = ms }
    }
    lastAnswer[r.id] = clock.now(); presence[r.machine] = clock.now(); answerDates[r.machine] = wallNow()
    return s
  }

  public func takeOutput(_ id: UUID, channel: String) async throws -> [ChannelPayload] {
    let key = "\(id)/consume/\(channel)"
    guard busy.insert(key).inserted else { throw OperationError(.capacityExceeded) }; defer { busy.remove(key) }
    let record = try await store.read(id); let output = record.output[channel] ?? []
    _ = try await store.transaction(id) { $0.output[channel]?.removeFirst(output.count) }; return output
  }

  public func write(_ id: UUID, channel: String, payload: ChannelPayload, end: Bool = false) async throws -> WriteReceipt {
    let key = "\(id)/input/\(channel)"
    guard busy.insert(key).inserted else { throw OperationError(.capacityExceeded) }; defer { busy.remove(key) }
    let r = try await active(id)
    guard let descriptor = r.description.kinds.first(where: { $0.name == r.start.kind })?.inputChannels.first(where: { $0.name == channel }) else { throw OperationError(.unknownChannel) }
    guard payload.byteCount <= min(descriptor.windowBytes, 64 * 1024) else { throw OperationError(.inputTooLarge) }
    let pending = r.pendingInputs[channel] ?? .init(offset: r.accepted[channel] ?? .zero, payload: payload, end: end)
    if let existing = r.pendingInputs[channel], existing.payload != payload || existing.end != end { throw OperationError(.invocationConflict) }
    _ = try await store.transaction(id) { $0.pendingInputs[channel] = pending }
    let receipt = try await request(
      WriteReceipt.self,
      url: address(r.machine, operation: id, suffix: "inputs/\(channel)"),
      method: .put,
      body: .json(pending),
      record: r,
    ) { receipt in
      let requestedEnd = try pending.offset.advanced(by: pending.payload.count)
      guard receipt.acceptedThrough >= pending.offset, receipt.acceptedThrough <= requestedEnd,
            !receipt.end || (pending.end && receipt.acceptedThrough == requestedEnd) else { throw OperationError(.invalidResponse) }
      return receipt
    }
    let requestedEnd = try pending.offset.advanced(by: pending.payload.count)
    _ = try await store.transaction(id) { value in
      try value.markEvidence()
      if value.unknown?.details != ["outcome": "unknown", "reason": "leaseSilence"] { value.unknown = nil }
      value.accepted[channel] = receipt.acceptedThrough
      if receipt.acceptedThrough == requestedEnd { value.pendingInputs.removeValue(forKey: channel) }
    }
    lastAnswer[id] = clock.now(); presence[r.machine] = clock.now(); answerDates[r.machine] = wallNow(); return receipt
  }

  public func stop(_ id: UUID, reason: String) async throws -> OperationSnapshot {
    try await sendStop(id, reason: reason)
  }

  func sendStop(_ id: UUID, reason: String, bestEffort: Bool = false) async throws -> OperationSnapshot {
    if !bestEffort { _ = try await active(id, allowStopped: true) }
    let r = try await store.transaction(id) { $0.stopReason = $0.stopReason ?? reason }
    callerDeadline.removeValue(forKey: id)
    let dispatchInFlight = dispatching.contains(id)
    do {
      return try await request(
        OperationSnapshot.self, url: address(r.machine, operation: id, suffix: "stop"), method: .put,
        body: .json(StopRequest(reason: r.stopReason ?? reason)), record: r, silenceBound: !bestEffort,
      ) { s in
        guard s.channel == nil else { throw OperationError(.invalidResponse) }
        return try await self.commit(s, record: r)
      }
    } catch let error as OperationError {
      if error.code == .unknownOperation { try await saveUnknown(error, record: r, dispatchInFlight: dispatchInFlight) }
      if !bestEffort && (error.code == .requestDeadline || error.code == .transport) { _ = try await active(id, allowStopped: true) }
      throw error
    }
  }

  /// Top-level input fields a closed (`additionalProperties: false`) input
  /// schema does not declare: an agent older than this caller, which would
  /// refuse them or ignore them. Nil when the kind's schema is open or absent.
  static func unadvertisedInputs(_ start: StartRequest, in description: MachineDescription) -> [String]? {
    guard let schema = description.kinds.first(where: { $0.name == start.kind })?.inputSchema.object,
          schema["additionalProperties"] == .bool(false),
          let properties = schema["properties"]?.object,
          let input = start.input.object
    else { return nil }
    return input.keys.filter { properties[$0] == nil }.sorted()
  }
}
