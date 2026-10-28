#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StopRequest
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteReceipt
import struct OperationProtocol.WriteRequest
import TaskLifetime

/// The only code that talks to a machine about one operation. One control lane sends the start (once, by the claim winner),
/// the stop, pending input and the terminal acknowledgement, and watches state otherwise; one lane per output channel takes
/// output while the channel's retained bytes leave room for a full poll. Every answer is durable before the next request
/// acknowledges it. The driver ends when the machine acknowledged the terminal record (retired) or with a diagnostic.
actor OperationDriver {
  static let backoff: (first: Duration, last: Duration) = (.milliseconds(100), .seconds(2))
  static let exchangeMargin: Duration = .seconds(5)

  private let link: MachineLink
  private let store: any OperationStore
  private(set) var record: ClientRecord
  private var dispatch: Bool
  private var stopSent = false
  private let leaseClock: LocalWorkClock
  private var lastAnswer: Duration
  private var startOutcome: Result<Void, OperationError>?
  private var generation: UInt64 = 0
  private var work: UInt64 = 0
  private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
  private let taskScope = TaskScope()
  private var running = false
  private let lifetime = AsyncStream<Void>.makeStream()
  private var locked = false
  private var lockQueue: [CheckedContinuation<Void, Never>] = []
  private var ended = false
  private var finished = false
  /// Set by `shutdown`: nothing of this driver writes the store again.
  private var fenced = false
  private let onEnd: @Sendable (UUID) async -> Void
  nonisolated let machine: String

  init(record: ClientRecord, dispatch: Bool, link: MachineLink, store: any OperationStore, onEnd: @escaping @Sendable (UUID) async -> Void) {
    self.record = record; self.dispatch = dispatch; self.link = link; self.store = store; self.onEnd = onEnd; machine = record.machine
    leaseClock = LocalWorkClock(link.clock)
    lastAnswer = link.clock.now()
    if !dispatch { startOutcome = .success(()) }
  }

  var leaseMs: Int { record.description.limits.leaseMs }
  var hold: Int { min(record.description.limits.pollHoldMs, leaseMs / 3) }
  /// Concurrent exchanges this driver holds: its control lane and one per output channel.
  var laneCount: Int { 1 + record.outputChannels.count }

  func run() async {
    guard !running, !ended else { return }
    running = true
    if !record.live { await end(); return }
    _ = try? taskScope.run("operation-control") { await self.controlLane() }
    if !dispatch { startOutputLanes() }
    for await _ in lifetime.stream {}
    await taskScope.close()
  }

  /// Stops the lanes and returns once no write of this driver is in flight; later writes fail, so a driver resumed over the same
  /// store is the record's only writer.
  func shutdown() async {
    fenced = true
    ended = true
    lifetime.continuation.finish()
    taskScope.cancel()
    wake()
    await lock()
    unlock()
    await taskScope.close()
  }

  // MARK: Consumer surface

  /// Waits for the start's outcome: dispatched, or the machine's typed refusal.
  func started() async throws {
    while true {
      if let startOutcome { return try startOutcome.get() }
      if let diagnostic = record.diagnostic { throw diagnostic }
      try checkOpen()
      await waitChange(since: generation)
    }
  }

  /// Retained chunks with sequence above `after`; nil once the verdict is known and every channel is drained past `after`.
  func output(after: UInt64?) async throws -> [OutputChunk]? {
    while true {
      let fresh = record.output.filter { chunk in after.map { chunk.sequence > $0 } ?? true }
      if !fresh.isEmpty { return fresh }
      if record.drained || record.retired { return nil }
      if let diagnostic = record.diagnostic { throw diagnostic }
      try checkOpen()
      await waitChange(since: generation)
    }
  }

  func acknowledge(_ channel: String, through: Offset) async throws {
    try await mutate { next in
      guard through > (next.consumed[channel] ?? .zero) else { return .none }
      guard through <= (next.committed[channel] ?? .zero) else { throw OperationError(.invalidOffset, operation: next.id) }
      next.consumed[channel] = through
      let removed = next.output.filter { $0.channel == channel && $0.through <= through }.map(\.sequence)
      next.output.removeAll { $0.channel == channel && $0.through <= through }
      return .trim(removed)
    }
  }

  /// Returns once the write is durable as the channel's pending input; the driver delivers it. Waits for an earlier write on
  /// the channel to be accepted first.
  func write(_ channel: String, payload: ChannelPayload, end: Bool) async throws {
    guard let descriptor = record.inputChannels.first(where: { $0.name == channel }) else { throw OperationError(.unknownChannel, operation: record.id) }
    guard payload.byteCount <= min(descriptor.windowBytes, 64 * 1024) else { throw OperationError(.inputTooLarge, operation: record.id) }
    while true {
      if record.snapshot?.verdict != nil || record.stopReason != nil || !record.live { throw OperationError(.operationEnded, operation: record.id) }
      if record.pendingInputs[channel] == nil { break }
      try checkOpen()
      await waitChange(since: generation)
    }
    try await mutate { next in
      guard next.pendingInputs[channel] == nil else { throw OperationError(.invocationConflict, operation: next.id) }
      next.pendingInputs[channel] = WriteRequest(offset: next.accepted[channel] ?? .zero, payload: payload, end: end)
      return .save(nil)
    }
    work += 1; wake()
  }

  /// Durable stop intent; the first reason wins.
  func stop(_ reason: String, consumer: JSONValue? = nil) async throws {
    try await mutate { next in
      guard next.stopReason == nil || consumer.map({ $0 != next.consumer }) == true else { return .none }
      next.stopReason = next.stopReason ?? reason
      if let consumer { next.consumer = consumer }
      return .save(nil)
    }
    work += 1; wake()
  }

  /// Stops the operation and drops its output, retained and future: nobody will read it. `consumer`, when given, replaces the
  /// consumer's state in the same write. An operation already concluded by a diagnostic the machine may not know about still
  /// gets the stop, best effort, so it does not run on until its lease lapses: true when the caller is to run `cleanupStop`.
  func abandon(_ reason: String, consumer: JSONValue? = nil) async throws -> Bool {
    let started = startOutcome.map { (try? $0.get()) != nil } ?? false
    var cleanup = false
    try await mutate { next in
      let stopping = next.stopReason == nil
      guard stopping || !next.discard || !next.output.isEmpty || consumer != nil else { return .none }
      if stopping, let diagnostic = next.diagnostic, next.snapshot?.verdict == nil, started, !Self.machineForgot(diagnostic) { cleanup = true }
      next.stopReason = next.stopReason ?? reason
      next.discard = true
      if let consumer { next.consumer = consumer }
      let removed = next.output.map(\.sequence)
      next.output = []
      return removed.isEmpty ? .save(nil) : .trim(removed)
    }
    work += 1; wake()
    return cleanup
  }

  func verdict() async throws -> Verdict {
    while true {
      if let verdict = record.snapshot?.verdict { return verdict }
      if let diagnostic = record.diagnostic { throw diagnostic }
      try checkOpen()
      await waitChange(since: generation)
    }
  }

  /// A driver shut down with the server leaves its consumers nothing to wait for.
  private func checkOpen() throws {
    try Task.checkCancellation()
    if ended { throw OperationError(.requestCancelled, message: "Operation driver stopped", operation: record.id) }
  }

  // MARK: Lanes

  private enum Step {
    case start, stop, input(String), acknowledge, renew, watch, done
  }

  private func nextStep() -> Step {
    if ended || !record.live { return .done }
    if dispatch { return .start }
    let verdict = record.snapshot?.verdict
    if verdict == nil, record.stopReason != nil, !stopSent { return .stop }
    if verdict == nil, record.stopReason == nil, let channel = record.pendingInputs.keys.sorted().first { return .input(channel) }
    if verdict != nil { return record.drained && record.output.isEmpty ? .acknowledge : .renew }
    return .watch
  }

  private func controlLane() async {
    var delay = Self.backoff.first
    while !Task.isCancelled {
      let failure: OperationError?
      switch nextStep() {
      case .done:
        await end(); return
      case .start:
        failure = await sendStart()
      case .stop:
        failure = await sendStop()
      case let .input(channel):
        failure = await sendInput(channel)
      case .acknowledge:
        failure = await sendTerminalAck()
      case .renew:
        // Terminal, output still with its consumer: keep the machine's terminal retention alive until it is drained.
        let since = generation
        failure = await pollState(hold: 0)
        if failure == nil { await waitChange(since: since, timeout: .milliseconds(leaseMs / 3)) }
      case .watch:
        failure = await watchState()
      }
      guard let failure else { delay = Self.backoff.first; continue }
      if await concludeIfFinal(failure) { await end(); return }
      await waitWork(since: work, timeout: delay)
      delay = min(delay * 2, Self.backoff.last)
    }
  }

  private func outputLane(_ channel: ChannelDescriptor) async {
    var delay = Self.backoff.first
    let poll = min(record.description.limits.pollBytes, channel.windowBytes)
    while !Task.isCancelled, !ended, record.live {
      if let final = record.snapshot?.finalOffsets[channel.name], record.snapshot?.verdict != nil, (record.committed[channel.name] ?? .zero) >= final { return }
      if !record.discard, record.retainedBytes(channel.name) + poll > channel.windowBytes {
        await waitChange(since: generation); continue
      }
      guard let failure = await pollChannel(channel) else { delay = Self.backoff.first; continue }
      if await concludeIfFinal(failure) { return }
      await waitChange(since: generation, timeout: delay)
      delay = min(delay * 2, Self.backoff.last)
    }
  }

  private func startOutputLanes() {
    for channel in record.outputChannels {
      _ = try? taskScope.run("operation-output-\(channel.name)") { await self.outputLane(channel) }
    }
  }

  // MARK: Exchanges

  private func deadline(hold: Int = 0) -> Duration {
    let normal = .milliseconds(hold) + Self.exchangeMargin
    let silence = lastAnswer + .milliseconds(leaseMs) - leaseClock.now()
    return max(.zero, min(normal, silence))
  }

  private func exchange<T: Decodable & Sendable>(_ type: T.Type, _ exchange: MachineExchange, body: Body? = nil, hold: Int = 0) async -> Result<T, OperationError> {
    let outcome = await link.send(type, record.machine, exchange, body: body, correlation: record.correlation, deadline: deadline(hold: hold), limit: OperationLimits.responseBytes, preparation: { [leaseClock] in leaseClock.work($0) })
    if outcome.answered { lastAnswer = leaseClock.now() }
    return outcome.result
  }

  private func sendStart() async -> OperationError? {
    let body: Body
    do { body = try .json(record.start) } catch { return await refuseStart(.init(.invalidInput, operation: record.id)) }
    switch await exchange(OperationSnapshot.self, .start(record.id), body: body) {
    case let .success(snapshot):
      // The machine took the start. A store that could not keep its answer loses nothing the state polls do not bring back;
      // only an answer that breaks the protocol refuses it.
      if let failure = await absorb(snapshot, channel: nil), disposition(failure.code) != .retry { return await refuseStart(failure) }
    case let .failure(error) where error.code == .operationExists:
      break
    case let .failure(error):
      // A capacity refusal is the machine declining the start, not a lost answer: retrying would only wait for room.
      if disposition(error.code) == .retry, error.code != .capacityExceeded { return error }
      return await refuseStart(error)
    }
    dispatch = false
    startOutcome = .success(())
    startOutputLanes()
    wake()
    return nil
  }

  /// A start the machine refused: the refusal is the diagnostic and the opener's error; nothing is retried.
  private func refuseStart(_ error: OperationError) async -> OperationError? {
    await conclude(OperationError(error.code, message: error.message, operation: record.id, details: error.details))
    return nil
  }

  /// The machine no longer holds the operation, or never answered for it: nothing to stop.
  private static func machineForgot(_ diagnostic: OperationError) -> Bool {
    [.unknownOperation, .unknownMachine, .machineNotAuthorized, .operationEnded].contains(diagnostic.code)
  }

  /// One stop for a concluded operation, retried while the machine answers within its lease.
  func cleanupStop() async {
    var delay = Self.backoff.first
    while !Task.isCancelled {
      guard let failure = await sendStop(), disposition(failure.code) == .retry, leaseClock.now() - lastAnswer < .milliseconds(leaseMs) else { return }
      try? await link.clock.sleep(delay)
      delay = min(delay * 2, Self.backoff.last)
    }
  }

  private func sendStop() async -> OperationError? {
    guard let reason = record.stopReason else { return nil }
    let body: Body
    do { body = try .json(StopRequest(reason: reason)) } catch { return .init(.invalidInput) }
    switch await exchange(OperationSnapshot.self, .stop(record.id), body: body) {
    case let .success(snapshot):
      if let failure = await absorb(snapshot, channel: nil) { return failure }
      stopSent = true
      do {
        try await mutate { next in
          guard !next.pendingInputs.isEmpty else { return .none }
          next.pendingInputs = [:]; return .save(nil)
        }
      } catch { return storeFailure(error) }
      return nil
    case let .failure(error): return error
    }
  }

  private func sendInput(_ channel: String) async -> OperationError? {
    guard let pending = record.pendingInputs[channel] else { return nil }
    let body: Body
    do { body = try .json(pending) } catch { return .init(.invalidInput) }
    switch await exchange(WriteReceipt.self, .input(record.id, channel: channel), body: body) {
    case let .success(receipt):
      let requested = Offset(rawValue: pending.offset.rawValue + UInt64(pending.payload.count))
      guard receipt.acceptedThrough >= pending.offset, receipt.acceptedThrough <= requested,
            !receipt.end || (pending.end && receipt.acceptedThrough == requested) else { return .init(.invalidResponse, operation: record.id) }
      do {
        try await mutate { next in
          next.accepted[channel] = receipt.acceptedThrough
          let taken = Int(receipt.acceptedThrough.rawValue - pending.offset.rawValue)
          if receipt.acceptedThrough == requested {
            next.pendingInputs[channel] = nil
          } else if taken > 0 {
            next.pendingInputs[channel] = WriteRequest(offset: receipt.acceptedThrough, payload: pending.payload.slice(taken ..< pending.payload.count), end: pending.end)
          }
          return .save(nil)
        }
      } catch { return storeFailure(error) }
      if receipt.blocked { await waitChange(since: generation, timeout: .milliseconds(250)) }
      return nil
    case let .failure(error) where error.code == .operationEnded:
      // The machine ended the operation (or holds a stop): the input has nowhere to go, the verdict comes by polling.
      do { try await mutate { next in next.pendingInputs[channel] = nil; return .save(nil) } } catch { return storeFailure(error) }
      return await pollState(hold: 0)
    case let .failure(error): return error
    }
  }

  private func sendTerminalAck() async -> OperationError? {
    guard let token = record.snapshot?.terminalToken, let snapshot = record.snapshot else { return .init(.invalidResponse, operation: record.id) }
    var answer: OperationSnapshot?
    let channels = record.outputChannels
    if channels.isEmpty {
      switch await exchange(OperationSnapshot.self, .poll(record.id, query: [.init(name: "holdMs", value: "0"), .init(name: "terminalAck", value: token.uuidString)])) {
      case let .success(value): answer = value
      case let .failure(error): return error
      }
      if let failure = await absorb(answer!, channel: nil) { return failure }
    }
    for channel in channels {
      let final = snapshot.finalOffsets[channel.name] ?? .zero
      let query: [URLQueryItem] = [.init(name: "holdMs", value: "0"), .init(name: "channel", value: channel.name), .init(name: "after", value: String(final.rawValue)), .init(name: "terminalAck", value: token.uuidString)]
      switch await exchange(OperationSnapshot.self, .poll(record.id, query: query)) {
      case let .success(value):
        if let failure = await absorb(value, channel: channel.name) { return failure }
        answer = value
      case let .failure(error): return error
      }
    }
    guard answer?.outputConsumed == true else {
      await waitChange(since: generation, timeout: .milliseconds(leaseMs / 3))
      return nil
    }
    do { try await mutate { next in next.terminalAcknowledged = true; return .save(nil) } } catch { return storeFailure(error) }
    return nil
  }

  private func pollState(hold: Int) async -> OperationError? {
    switch await exchange(OperationSnapshot.self, .poll(record.id, query: [.init(name: "holdMs", value: String(hold))]), hold: hold) {
    case let .success(snapshot): return await absorb(snapshot, channel: nil)
    case let .failure(error): return error
    }
  }

  /// A held state poll, abandoned as soon as there is work for the control lane (a stop or input).
  private func watchState() async -> OperationError? {
    enum Race: Sendable { case polled(OperationError?), work }
    let since = work
    let hold = hold
    return await withTaskGroup(of: Race.self) { group in
      group.addTask { .polled(await self.pollState(hold: hold)) }
      group.addTask { await self.waitWork(since: since, timeout: nil); return .work }
      let first = await group.next() ?? .work
      group.cancelAll()
      if case let .polled(failure) = first { return failure }
      return nil
    }
  }

  private func pollChannel(_ channel: ChannelDescriptor) async -> OperationError? {
    let hold = record.snapshot?.verdict == nil ? hold : 0
    let after = record.committed[channel.name] ?? .zero
    let query: [URLQueryItem] = [.init(name: "holdMs", value: String(hold)), .init(name: "channel", value: channel.name), .init(name: "after", value: String(after.rawValue))]
    switch await exchange(OperationSnapshot.self, .poll(record.id, query: query), hold: hold) {
    case let .success(snapshot): return await absorb(snapshot, channel: channel.name)
    case let .failure(error): return error
    }
  }

  /// Validates an answer and makes it durable: one appended chunk for a channel poll, the record when the verdict or
  /// consumption state changes. A pre-verdict answer arriving after the verdict keeps only its continuing channel bytes.
  private func absorb(_ s: OperationSnapshot, channel: String?) async -> OperationError? {
    do {
      try await mutate { next in
        let invalid = OperationError(.invalidResponse, operation: next.id)
        guard s.operation == next.id, (s.verdict == nil) == (s.terminalToken == nil), s.channel == channel else { throw invalid }
        guard (s.verdict?.result?.jsonString().utf8.count ?? 0) <= next.description.limits.resultBytes else { throw OperationError(.resultTooLarge, operation: next.id) }
        if let known = next.snapshot?.verdict, let verdict = s.verdict, known != verdict { throw invalid }
        let stale = next.snapshot?.verdict != nil && s.verdict == nil
        var chunk: OutputChunk?
        var changed = false
        if let channel {
          let committed = next.committed[channel] ?? .zero
          guard let from = s.from, let payload = s.payload, let through = s.through else { throw invalid }
          if !(stale && from != committed) {
            guard let descriptor = next.outputChannels.first(where: { $0.name == channel }), from == committed,
                  through.rawValue == from.rawValue + UInt64(payload.count),
                  (descriptor.unit == .bytes && payload.data != nil && payload.records == nil) || (descriptor.unit == .records && payload.records != nil && payload.data == nil),
                  payload.byteCount <= next.description.limits.pollBytes,
                  payload.records?.allSatisfy({ $0.jsonString().utf8.count <= descriptor.maxRecordBytes }) ?? true else { throw invalid }
            if payload.count > 0 {
              next.committed[channel] = through
              changed = true
              if !next.discard {
                guard next.retainedBytes(channel) + payload.byteCount <= descriptor.windowBytes else { throw invalid }
                let value = OutputChunk(sequence: next.nextSequence, channel: channel, from: from, payload: payload)
                next.nextSequence += 1
                next.output.append(value)
                chunk = value
              }
            }
          }
        }
        if !stale {
          if next.snapshot?.verdict == nil && s.verdict != nil || next.snapshot?.outputConsumed != s.outputConsumed { changed = true }
          next.snapshot = s
        }
        return changed ? .save(chunk) : .memory
      }
      return nil
    } catch let error as OperationError {
      return error
    } catch { return storeFailure(error) }
  }

  // MARK: State

  private enum Persist {
    case none, memory, save(OutputChunk?), trim([UInt64])
  }

  /// Serializes every record change: the change is computed on a copy, made durable, then published.
  private func mutate(_ change: (inout ClientRecord) throws -> Persist) async throws {
    await lock()
    defer { unlock() }
    if fenced { throw OperationError(.requestCancelled, message: "Operation driver stopped", operation: record.id) }
    var next = record
    let persist = try change(&next)
    leaseClock.work(true)
    defer { leaseClock.work(false) }
    switch persist {
    case .none: return
    case .memory: break
    case let .save(chunk): try await store.save(next, appending: chunk)
    case let .trim(sequences): try await store.trim(next, removing: sequences)
    }
    record = next
    wake()
  }

  private func storeFailure(_ error: any Error) -> OperationError {
    error as? OperationError ?? OperationError(.storeUnavailable, message: String(describing: error), operation: record.id)
  }

  /// Retries transient failures until the machine has been silent for its lease; anything else is the diagnostic.
  private func concludeIfFinal(_ error: OperationError) async -> Bool {
    if ended || !record.live { return true }
    if error.code == .unknownOperation, record.snapshot?.verdict != nil, record.drained, record.output.isEmpty {
      // The machine drops an operation once it is settled: a terminal acknowledgement whose answer was lost finds it gone.
      do { try await mutate { next in next.terminalAcknowledged = true; return .save(nil) } } catch {
        record.terminalAcknowledged = true
        wake()
      }
      return true
    }
    let diagnostic: OperationError
    if disposition(error.code) == .retry {
      guard leaseClock.now() - lastAnswer >= .milliseconds(leaseMs) else { return false }
      diagnostic = OperationError(.unknownOperation, message: "Machine was silent for the operation's lease", operation: record.id, details: ["outcome": "unknown", "reason": "leaseSilence", "cause": .string(error.code.rawValue)])
    } else {
      diagnostic = OperationError(error.code, message: error.message, operation: record.id, details: error.details)
    }
    await conclude(diagnostic)
    return true
  }

  /// Ends the operation with `diagnostic`, persisted when the store takes it.
  private func conclude(_ diagnostic: OperationError) async {
    if dispatch, startOutcome == nil { startOutcome = .failure(diagnostic) }
    do {
      try await mutate { next in
        guard next.live else { return .none }
        next.diagnostic = diagnostic; next.pendingInputs = [:]; return .save(nil)
      }
    } catch {
      // The store is down: keep the diagnostic in memory so consumers end; boot resumes the row later.
      record.diagnostic = diagnostic
      wake()
    }
  }

  private func end() async {
    guard !finished else { return }
    finished = true
    ended = true
    lifetime.continuation.finish()
    taskScope.cancel()
    wake()
    let id = record.id
    await onEnd(id)
  }

  private func wake() {
    generation += 1
    let current = waiters
    waiters = [:]
    for waiter in current.values { waiter.finish() }
  }

  private func lock() async {
    if !locked { locked = true; return }
    await withCheckedContinuation { lockQueue.append($0) }
  }

  private func unlock() {
    if lockQueue.isEmpty { locked = false } else { lockQueue.removeFirst().resume() }
  }

  private func waitGeneration(_ since: UInt64) async {
    guard generation <= since, !ended else { return }
    let id = UUID()
    let (signal, continuation) = AsyncStream<Void>.makeStream()
    waiters[id] = continuation
    defer { waiters[id] = nil }
    for await _ in signal {}
  }

  private func waitWorkGeneration(_ since: UInt64) async {
    while work <= since, !ended, record.live, !Task.isCancelled { await waitGeneration(generation) }
  }

  /// Until the record changes (or the driver ends), at most `timeout`.
  func waitChange(since: UInt64, timeout: Duration? = nil) async {
    await race(timeout) { await self.waitGeneration(since) }
  }

  /// Until a stop or input arrives, at most `timeout`.
  private func waitWork(since: UInt64, timeout: Duration?) async {
    await race(timeout) { await self.waitWorkGeneration(since) }
  }

  private func race(_ timeout: Duration?, _ body: @escaping @Sendable () async -> Void) async {
    guard let timeout else { await body(); return }
    let clock = link.clock
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await body() }
      group.addTask { try? await clock.sleep(timeout) }
      await group.next()
      group.cancelAll()
    }
  }
}
