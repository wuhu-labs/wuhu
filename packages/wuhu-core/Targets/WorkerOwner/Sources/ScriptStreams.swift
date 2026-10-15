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
  private var active: Set<UUID> = []
  private var opening = 0
  private var stopped = false
  func stop() { stopped = true; bodies.removeAll(); active.removeAll() }
  func open(_ call: WorkerCall, owner: any ScriptOwnerClient) async throws -> UUID {
    guard !stopped, active.count + opening < 256 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many pending script streams") }
    opening += 1
    defer { opening -= 1 }
    let body: Body
    switch call.operation {
    case "script.observe-open":
      let request = try ownerDecode(ObserveRequest.self, call.payload)
      let source = try await owner.observe(request.sql, parameters: request.parameters, session: request.session)
      let reader = RowsStreamReader(source)
      let values = AsyncThrowingStream<RowsSnapshot, any Error>(unfolding: { try await reader.next() })
      body = .stream(OwnerRecordSequence(source: values))
    case "script.watch-open":
      let request = try ownerDecode(WatchRequest.self, call.payload)
      body = try await .stream(OwnerRecordSequence(source: owner.watch(request.glob, from: request.from.map(Rev.init), session: request.session)))
    default: throw WorkerProtocolError(.invalidMessage, message: "Unknown script stream")
    }
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    let id = call.id
    active.insert(id)
    bodies[id] = .stream(OwnerResourceBytes(body: body, finished: { await self.cancel(id) }))
    return id
  }

  func cancel(_ id: UUID) { bodies[id] = nil; active.remove(id) }
  func take(_ id: UUID) throws -> Body {
    guard let body = bodies.removeValue(forKey: id) else { throw WorkerProtocolError(.invalidMessage, message: "Unknown script stream") }
    return body
  }
}

private actor RowsStreamReader {
  var iterator: AsyncThrowingStream<Rows, any Error>.Iterator?
  init(_ source: AsyncThrowingStream<Rows, any Error>) { iterator = source.makeAsyncIterator() }
  func next() async throws -> RowsSnapshot? {
    guard var iterator else { throw WorkerProtocolError(.invalidMessage, message: "Concurrent query stream reader") }
    self.iterator = nil
    defer { self.iterator = iterator }
    return try await iterator.next(isolation: self).map(RowsSnapshot.init)
  }
}

extension RemoteExecutionOwner {
  public func observe(_ sql: String, parameters: [JSONValue], session: SessionID) async throws -> AsyncThrowingStream<Rows, any Error> {
    let id: UUID = try await rpc.call("script.observe-open", ObserveRequest(sql: sql, parameters: parameters, session: session))
    let body = try await rpc.resource("script.stream", id: id)
    let reader = OwnerRecordReader<RowsSnapshot>(body)
    return AsyncThrowingStream(unfolding: { try await reader.next()?.value() })
  }

  public func watch(_ glob: String, from: Rev?, session: SessionID) async throws -> AsyncThrowingStream<JSONValue, any Error> {
    let id: UUID = try await rpc.call("script.watch-open", WatchRequest(glob: glob, from: from?.value, session: session))
    let body = try await rpc.resource("script.stream", id: id)
    let reader = OwnerRecordReader<JSONValue>(body)
    return AsyncThrowingStream(unfolding: { try await reader.next() })
  }
}
