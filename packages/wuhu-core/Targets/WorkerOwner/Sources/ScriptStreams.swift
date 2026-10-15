#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import protocol SessionTools.ScriptOwnerClient
import struct SpaceCore.Rev
import struct SpaceCore.Rows
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

struct ObserveRequest: Codable, Sendable { let sql: String; let parameters: [JSONValue]; let session: SessionID }
struct WatchRequest: Codable, Sendable { let glob: String; let from: Int?; let session: SessionID }
struct StreamRequest: Codable, Sendable { let id: UUID }

actor ParentScriptStreams {
  private var bodies: [UUID: Body] = [:]
  private var retained: [UUID: RetainedScriptStream] = [:]
  private var definitions: [UUID: WorkerCall] = [:]
  private var active: Set<UUID> = []
  private var opening = 0
  private var stopped = false
  private var suspended = false
  func stop() async {
    stopped = true
    let streams = Array(retained.values)
    retained.removeAll(); definitions.removeAll(); bodies.removeAll(); active.removeAll()
    for stream in streams { await stream.cancel() }
  }

  func open(_ call: WorkerCall, owner: any ScriptOwnerClient) async throws -> UUID {
    guard !suspended else { throw WorkerProtocolError(.unavailable, message: "Script stream admission is paused") }
    guard !stopped, active.count + opening < 256 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many pending script streams") }
    opening += 1
    defer { opening -= 1 }
    let cursor: ScriptStreamCursor
    switch call.operation {
    case "script.observe-open": cursor = ScriptStreamCursor()
    case "script.watch-open":
      let request = try ownerDecode(WatchRequest.self, call.payload)
      let revision: Int
      if let from = request.from { revision = from }
      else { revision = try await owner.moduleSnapshot(for: request.session).revision.value }
      cursor = ScriptStreamCursor(revision: revision)
    default: throw WorkerProtocolError(.invalidMessage, message: "Unknown script stream")
    }
    let overflow = ScriptWatchOverflow()
    let source = Self.source(call, owner: owner, overflow: overflow)
    let values = try await source(cursor)
    let body = Body.stream(OwnerRecordSequence(source: values))
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    let id = call.id
    active.insert(id)
    if call.receipt != nil {
      definitions[id] = call
      retained[id] = RetainedScriptStream(source: source, reader: OwnerRecordReader<JSONValue>(body), cursor: cursor, overflow: overflow)
    } else {
      bodies[id] = .stream(OwnerResourceBytes(body: body, finished: { await self.cancel(id) }))
    }
    return id
  }

  func cancel(_ id: UUID) async {
    let stream = retained.removeValue(forKey: id)
    bodies[id] = nil; definitions[id] = nil; active.remove(id)
    await stream?.cancel()
  }

  func inventory() async -> [WorkerStreamInventory] {
    var streams: [WorkerStreamInventory] = []
    let readers = retained.compactMap { id, stream in definitions[id].map { (id, stream, $0.operation) } }
    for (id, stream, operation) in readers {
      streams.append(await WorkerStreamInventory(id: id, operation: operation, marker: stream.marker, revision: stream.revision))
    }
    return streams
  }

  func next(_ id: UUID, call: UUID) async throws -> OwnerRecord {
    guard let stream = retained[id] else { throw WorkerProtocolError(.invalidMessage, message: "Unknown retained script stream") }
    return try await stream.next(call)
  }

  func acknowledge(_ call: WorkerCall) async {
    guard call.operation == "script.stream-next", let request = try? ownerDecode(StreamRequest.self, call.payload) else { return }
    await retained[request.id]?.acknowledge(call.id)
  }

  func suspend() async throws {
    guard active.count == retained.count, opening == 0 else { throw WorkerProtocolError(.unavailable, message: "Legacy or opening script streams cannot be checkpointed") }
    suspended = true
    for stream in retained.values { await stream.suspend() }
  }

  func checkpoint(retaining calls: Set<UUID>) async throws -> [ScriptStreamCheckpoint] {
    guard suspended else { throw WorkerProtocolError(.invalidConfiguration, message: "Logical readers are not suspended") }
    var result: [ScriptStreamCheckpoint] = []
    let streams = retained.compactMap { id, stream in definitions[id].map { ($0, stream) } }
    for (definition, stream) in streams {
      result.append(try await ScriptStreamCheckpoint(definition: definition, reader: stream.checkpoint(retaining: calls)))
    }
    guard try JSONEncoder().encode(result).count <= 128 << 20 else { throw WorkerProtocolError(.capacityExceeded, message: "Logical reader checkpoint exceeds byte limit") }
    return result
  }

  func restore(_ checkpoints: [ScriptStreamCheckpoint], owner: any ScriptOwnerClient) throws {
    guard !stopped, active.isEmpty, checkpoints.count <= 256, Set(checkpoints.map { $0.definition.id }).count == checkpoints.count else { throw WorkerProtocolError(.invalidMessage, message: "Invalid logical reader checkpoint set") }
    guard try JSONEncoder().encode(checkpoints).count <= 128 << 20 else { throw WorkerProtocolError(.capacityExceeded, message: "Logical reader checkpoint exceeds byte limit") }
    var restored: [UUID: RetainedScriptStream] = [:]
    for checkpoint in checkpoints {
      let definition = checkpoint.definition
      guard definition.operation == "script.observe-open" || definition.operation == "script.watch-open", definition.receipt != nil else { throw WorkerProtocolError(.invalidMessage, message: "Invalid logical reader definition") }
      try checkpoint.validate()
      let overflow = ScriptWatchOverflow()
      restored[definition.id] = try RetainedScriptStream(source: Self.source(definition, owner: owner, overflow: overflow), checkpoint: checkpoint.reader, overflow: overflow)
    }
    retained = restored
    definitions = Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.definition.id, $0.definition) })
    active = Set(restored.keys)
    suspended = true
  }

  func resume() async {
    for stream in retained.values { await stream.resume() }
    suspended = false
  }

  func take(_ id: UUID) throws -> Body {
    guard let body = bodies.removeValue(forKey: id) else { throw WorkerProtocolError(.invalidMessage, message: "Unknown script stream") }
    return body
  }
}

extension RemoteExecutionOwner {
  public func observe(_ sql: String, parameters: [JSONValue], session: SessionID) async throws -> AsyncThrowingStream<Rows, any Error> {
    let id: UUID = try await rpc.call("script.observe-open", ObserveRequest(sql: sql, parameters: parameters, session: session))
    if await rpc.client.retainsReplies {
      let reader = RemoteScriptStream<RowsSnapshot>(rpc: rpc, id: id)
      return AsyncThrowingStream(unfolding: { try await reader.next()?.value() })
    }
    let body = try await rpc.resource("script.stream", id: id)
    let reader = OwnerRecordReader<RowsSnapshot>(body)
    return AsyncThrowingStream(unfolding: { try await reader.next()?.value() })
  }

  public func watch(_ glob: String, from: Rev?, session: SessionID) async throws -> AsyncThrowingStream<JSONValue, any Error> {
    let id: UUID = try await rpc.call("script.watch-open", WatchRequest(glob: glob, from: from?.value, session: session))
    if await rpc.client.retainsReplies {
      let reader = RemoteScriptStream<JSONValue>(rpc: rpc, id: id)
      return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    let body = try await rpc.resource("script.stream", id: id)
    let reader = OwnerRecordReader<JSONValue>(body)
    return AsyncThrowingStream(unfolding: { try await reader.next() })
  }
}
