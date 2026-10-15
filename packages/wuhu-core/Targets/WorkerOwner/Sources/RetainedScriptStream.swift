#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import enum JSONValue.JSONValue
import Synchronization
import struct WorkerProtocol.WorkerProtocolError

struct ScriptStreamCursor: Codable, Sendable {
  var marker: JSONValue?
  var revision: Int?
  var acknowledgedInRevision: [JSONValue] = []

  mutating func consume(_ value: JSONValue) {
    marker = value
    if let rev = value.object?["rev"]?.intValue {
      if revision != rev { acknowledgedInRevision = [] }
      revision = rev
      acknowledgedInRevision.append(value)
    }
  }
}

struct ScriptReaderCheckpoint: Codable, Sendable {
  let cursor: ScriptStreamCursor
  let stagedID: UUID?
  let stagedValue: JSONValue?
  let ended: Bool
  let overflowed: Bool
}

final class ScriptWatchOverflow: Sendable {
  private let state = Mutex(false)
  var occurred: Bool { state.withLock { $0 } }
  func mark() { state.withLock { $0 = true } }
}

actor RetainedScriptStream {
  typealias Source = @Sendable (ScriptStreamCursor) async throws -> AsyncThrowingStream<JSONValue, any Error>
  private let source: Source
  private let overflow: ScriptWatchOverflow
  private var reader: OwnerRecordReader<JSONValue>?
  private var ended = false
  private var suspended = false
  private var pending: Task<JSONValue?, any Error>?
  private var staged: (id: UUID, value: JSONValue)?
  private var cursor: ScriptStreamCursor
  private(set) var marker: JSONValue?
  private(set) var revision: Int?

  init(source: @escaping Source, reader: OwnerRecordReader<JSONValue>, cursor: ScriptStreamCursor, overflow: ScriptWatchOverflow = .init()) {
    self.source = source; self.reader = reader; self.cursor = cursor; self.overflow = overflow
  }

  init(source: @escaping Source, checkpoint: ScriptReaderCheckpoint, overflow: ScriptWatchOverflow) throws {
    guard (checkpoint.stagedID == nil) == (checkpoint.stagedValue == nil) else { throw WorkerProtocolError(.invalidMessage, message: "Incomplete script reader checkpoint") }
    self.source = source; cursor = checkpoint.cursor; ended = checkpoint.ended; self.overflow = overflow
    if checkpoint.overflowed { overflow.mark() }
    if let id = checkpoint.stagedID, let value = checkpoint.stagedValue { staged = (id, value) }
    marker = checkpoint.stagedValue ?? checkpoint.cursor.marker
    revision = marker?.object?["rev"]?.intValue ?? checkpoint.cursor.revision
    suspended = true
  }

  func next(_ call: UUID) async throws -> OwnerRecord {
    guard pending == nil, staged == nil, !ended else { throw WorkerProtocolError(.invalidMessage, message: "Script stream already has an outstanding read or is closed") }
    if suspended { return OwnerRecord(value: nil, fault: nil, ended: false, suspended: true) }
    if reader == nil, overflow.occurred { throw WorkerProtocolError(.capacityExceeded, message: "Script watch exceeded its retained event window before suspension") }
    let cursor = cursor
    let current = reader
    let source = source
    let task = Task {
      let reader: OwnerRecordReader<JSONValue>
      if let current { reader = current }
      else { reader = try await OwnerRecordReader(.stream(OwnerRecordSequence(source: source(cursor)))) }
      self.install(reader)
      return try await reader.next()
    }
    pending = task
    let value: JSONValue?
    do {
      value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      try Task.checkCancellation()
    } catch {
      pending = nil
      if suspended, error is CancellationError, !Task.isCancelled { return OwnerRecord(value: nil, fault: nil, ended: false, suspended: true) }
      throw error
    }
    pending = nil
    if suspended, value == nil { return OwnerRecord(value: nil, fault: nil, ended: false, suspended: true) }
    ended = value == nil
    marker = value
    revision = value?.object?["rev"]?.intValue ?? revision
    if let value { staged = (call, value) }
    return OwnerRecord(value: value, fault: nil, ended: value == nil)
  }

  private func install(_ reader: OwnerRecordReader<JSONValue>) { self.reader = reader }

  func acknowledge(_ call: UUID) {
    guard let staged, staged.id == call else { return }
    cursor.consume(staged.value)
    self.staged = nil
  }

  func suspend() async {
    suspended = true
    let task = pending
    task?.cancel()
    _ = try? await task?.value
    reader = nil
  }

  func checkpoint(retaining calls: Set<UUID>) throws -> ScriptReaderCheckpoint {
    guard suspended, pending == nil else { throw WorkerProtocolError(.unavailable, message: "Script reader is not suspended") }
    if let staged, !calls.contains(staged.id) { acknowledge(staged.id) }
    return ScriptReaderCheckpoint(cursor: cursor, stagedID: staged?.id, stagedValue: staged?.value, ended: ended, overflowed: overflow.occurred)
  }

  func resume() { suspended = false }

  func cancel() async {
    let task = pending
    task?.cancel()
    _ = try? await task?.value
    reader = nil
    ended = true
  }
}

actor RemoteScriptStream<Value: Decodable & Sendable> {
  let rpc: OwnerRPC
  let id: UUID
  private var ended = false
  init(rpc: OwnerRPC, id: UUID) { self.rpc = rpc; self.id = id }

  deinit {
    let rpc = rpc, id = id
    Task { await rpc.cancel(id) }
  }

  func next() async throws -> Value? {
    guard !ended else { return nil }
    do {
      var record: OwnerRecord = try await rpc.call("script.stream-next", StreamRequest(id: id))
      while record.suspended == true {
        try Task.checkCancellation()
        record = try await rpc.call("script.stream-next", StreamRequest(id: id))
      }
      if let fault = record.fault { throw try fault.error() }
      if record.ended { ended = true; await rpc.cancel(id); return nil }
      guard let value = record.value else { throw WorkerProtocolError(.invalidMessage, message: "Missing script stream value") }
      return try ownerDecode(Value.self, value)
    } catch {
      ended = true
      await rpc.cancel(id)
      throw error
    }
  }
}

func boundedScriptWatch(_ source: AsyncThrowingStream<JSONValue, any Error>, onOverflow: @escaping @Sendable () -> Void = {}) -> AsyncThrowingStream<JSONValue, any Error> {
  AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
    let pump = Task {
      do {
        for try await value in source {
          switch continuation.yield(value) {
          case .enqueued: continue
          case .dropped:
            onOverflow()
            continuation.finish(throwing: WorkerProtocolError(.capacityExceeded, message: "Script watch consumer exceeded its retained event window"))
            return
          case .terminated: return
          @unknown default: return
          }
        }
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    continuation.onTermination = { _ in pump.cancel() }
  }
}
