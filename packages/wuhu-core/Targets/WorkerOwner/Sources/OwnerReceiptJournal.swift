#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerCallInventory
import struct WorkerProtocol.WorkerProtocolError
import struct WorkerProtocol.WorkerReceipt
import struct WorkerProtocol.WorkerReply

actor OwnerReceiptJournal {
  nonisolated let identity: UUID
  init() { identity = UUID() }

  init(restoring checkpoint: OwnerReceiptCheckpoint) throws {
    let restored = try checkpoint.restore()
    identity = checkpoint.identity
    clients = restored.clients
    retainedBytes = restored.bytes
    pause = UUID()
  }

  struct Entry {
    let call: WorkerCall
    let task: Task<WorkerReply, Never>
    var reply: WorkerReply?
    var terminal: Bool { reply != nil }
    var waiters: [UUID: AsyncStream<WorkerReply>.Continuation] = [:]
    var bytes: Int
  }

  struct Client {
    var consumed = 0
    var acknowledged: Set<Int> = []
    var entries: [Int: Entry] = [:]
  }

  private var clients: [UUID: Client] = [:]
  private var stopped = false
  private var pause: UUID?
  private var sealed = false
  private var retainedBytes = 0

  func run(_ call: WorkerCall, invoke: @escaping @Sendable () async throws -> JSONValue) async throws -> WorkerReply {
    let receipt = try validate(call.receipt)
    guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Owner receipt journal is closed") }
    var client = clients[receipt.client] ?? Client()
    guard receipt.sequence > client.consumed, !client.acknowledged.contains(receipt.sequence) else {
      throw WorkerProtocolError(.consumedReceipt, message: "Owner receipt was already consumed; effect cannot be readmitted")
    }
    if let entry = client.entries[receipt.sequence] {
      guard entry.call == call else { throw WorkerProtocolError(.invalidMessage, message: "Owner receipt does not match its admitted effect") }
      return try await wait(receipt)
    }
    guard pause == nil else { throw WorkerProtocolError(.unavailable, message: "Owner effect admission is paused for parent replacement") }
    guard clients.count < 16 || clients[receipt.client] != nil,
          receipt.sequence - client.consumed <= 1024,
          clients.values.reduce(0, { $0 + $1.entries.count }) < 1024
    else { throw WorkerProtocolError(.capacityExceeded, message: "Owner receipt journal requires acknowledgement before admitting more effects") }
    let inputBytes = call.payload.jsonString().utf8.count
    guard inputBytes <= 64 << 20, retainedBytes + inputBytes + 1024 <= 128 << 20 else {
      throw WorkerProtocolError(.capacityExceeded, message: "Owner receipt journal byte budget exhausted")
    }
    let task = Task {
      let reply: WorkerReply
      do { reply = try await WorkerReply(id: call.id, result: invoke()) }
      catch is CancellationError { reply = WorkerReply(id: call.id, error: .init(.cancelled, message: "Owner operation was cancelled")) }
      catch let error as WorkerProtocolError { reply = WorkerReply(id: call.id, error: error) }
      catch { reply = WorkerReply(id: call.id, error: .init(.remoteFailure, message: "Owner operation failed")) }
      return bounded(reply, receipt: receipt)
    }
    retainedBytes += inputBytes + 1024
    client.entries[receipt.sequence] = Entry(call: call, task: task, bytes: inputBytes + 1024)
    clients[receipt.client] = client
    return try await wait(receipt)
  }

  func value(_ call: WorkerCall) async throws -> WorkerReply {
    let receipt = try validate(call.receipt)
    guard let entry = clients[receipt.client]?.entries[receipt.sequence], entry.call.id == call.id,
          entry.call.operation == call.payload.stringValue
    else { throw WorkerProtocolError(.invalidMessage, message: "Unknown retained owner reply") }
    return try await wait(receipt)
  }

  private func wait(_ receipt: WorkerReceipt) async throws -> WorkerReply {
    guard let entry = clients[receipt.client]?.entries[receipt.sequence] else { throw WorkerProtocolError(.invalidMessage, message: "Unknown retained owner reply") }
    if let reply = entry.reply { return reply }
    let id = UUID()
    let (stream, continuation) = AsyncStream<WorkerReply>.makeStream(bufferingPolicy: .bufferingNewest(1))
    clients[receipt.client]?.entries[receipt.sequence]?.waiters[id] = continuation
    defer { clients[receipt.client]?.entries[receipt.sequence]?.waiters[id] = nil }
    var iterator = stream.makeAsyncIterator()
    guard let reply = await iterator.next() else { throw CancellationError() }
    try Task.checkCancellation()
    return reply
  }

  @discardableResult
  func acknowledge(_ receipt: WorkerReceipt) throws -> WorkerCall? {
    _ = try validate(receipt)
    guard clients.count < 16 || clients[receipt.client] != nil else { throw WorkerProtocolError(.capacityExceeded, message: "Owner receipt client budget exhausted") }
    var client = clients[receipt.client] ?? Client()
    if receipt.sequence <= client.consumed || client.acknowledged.contains(receipt.sequence) { return nil }
    guard !sealed else { throw WorkerProtocolError(.unavailable, message: "Owner acknowledgements are sealed for parent replacement") }
    guard receipt.sequence - client.consumed <= 1024 else { throw WorkerProtocolError(.invalidMessage, message: "Owner acknowledgement is outside its receipt window") }
    guard client.entries[receipt.sequence]?.terminal != false else { throw WorkerProtocolError(.invalidMessage, message: "Running owner effect cannot be acknowledged") }
    let call = client.entries[receipt.sequence]?.call
    retainedBytes -= client.entries[receipt.sequence]?.bytes ?? 0
    client.entries[receipt.sequence] = nil
    client.acknowledged.insert(receipt.sequence)
    while client.consumed < Int.max, client.acknowledged.remove(client.consumed + 1) != nil { client.consumed += 1 }
    clients[receipt.client] = client
    return call
  }

  func cancel(_ id: UUID) async {
    let calls = clients.values.flatMap { $0.entries.values }.filter { $0.call.id == id }
    for entry in calls { entry.task.cancel() }
    for entry in calls {
      _ = await entry.task.value
    }
  }

  func inventory() -> [WorkerCallInventory] { clients.values.flatMap { $0.entries.values.map { WorkerCallInventory($0.call, terminal: $0.terminal) } } }

  func pauseAdmission() throws -> UUID {
    guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Owner receipt journal is closed") }
    if let pause { return pause }
    let token = UUID()
    pause = token
    return token
  }

  func resumeAdmission(_ token: UUID) throws {
    try requirePause(token)
    pause = nil
    sealed = false
  }

  func quiesce(_ token: UUID, excluding operations: Set<String> = []) async throws -> [WorkerCallInventory] {
    try requirePause(token)
    let tasks = clients.values.flatMap { $0.entries.values }
      .filter { !operations.contains($0.call.operation) }.map(\.task)
    for task in tasks { _ = await task.value }
    try requirePause(token)
    return inventory().filter { !$0.terminal }
  }

  func checkpoint(_ token: UUID) throws -> OwnerReceiptCheckpoint {
    try requirePause(token)
    guard clients.values.allSatisfy({ $0.entries.values.allSatisfy(\.terminal) }) else {
      throw WorkerProtocolError(.unavailable, message: "Owner calls remain active; reader suspension is required before checkpoint")
    }
    sealed = true
    return OwnerReceiptCheckpoint(identity: identity, clients: clients.map { id, client in
      .init(id: id, consumed: client.consumed, acknowledged: client.acknowledged, entries: client.entries.values.map { entry in
        .init(call: entry.call, reply: entry.reply!)
      })
    })
  }

  private func requirePause(_ token: UUID) throws {
    guard !stopped, pause == token else { throw WorkerProtocolError(.invalidConfiguration, message: "Parent replacement pause is no longer current") }
  }

  func stop() async {
    stopped = true
    let tasks = clients.values.flatMap { $0.entries.values.map(\.task) }
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.result }
    clients.removeAll(); retainedBytes = 0
  }

  private func bounded(_ reply: WorkerReply, receipt: WorkerReceipt) -> WorkerReply {
    let size = (try? JSONEncoder().encode(reply).count) ?? Int.max
    let retained: WorkerReply
    let bytes: Int
    if size <= 64 << 20, size <= (128 << 20) - retainedBytes + 1024 {
      retained = reply; bytes = size
    } else {
      retained = WorkerReply(id: reply.id, error: .init(.capacityExceeded, message: "Owner effect completed but its reply exceeds the retained byte budget"))
      bytes = 1024
    }
    retainedBytes += bytes - 1024
    clients[receipt.client]?.entries[receipt.sequence]?.bytes += bytes - 1024
    clients[receipt.client]?.entries[receipt.sequence]?.reply = retained
    let waiters = clients[receipt.client]?.entries[receipt.sequence]?.waiters.values.map { $0 } ?? []
    clients[receipt.client]?.entries[receipt.sequence]?.waiters = [:]
    for waiter in waiters { waiter.yield(retained); waiter.finish() }
    return retained
  }

  private func validate(_ receipt: WorkerReceipt?) throws -> WorkerReceipt {
    guard let receipt, receipt.endpoint == identity else {
      throw WorkerProtocolError(.unknownOutcome, message: "Owner receipt belongs to a different journal; explicit reconciliation is required")
    }
    guard receipt.sequence > 0 else { throw WorkerProtocolError(.invalidMessage, message: "Owner receipt sequence must be positive") }
    return receipt
  }
}
