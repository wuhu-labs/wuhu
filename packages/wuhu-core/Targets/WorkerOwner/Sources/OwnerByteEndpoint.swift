import struct Fetch.Body
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerEndpoint
import struct WorkerProtocol.WorkerHello
import struct WorkerProtocol.WorkerProtocolError

public struct OwnerByteEndpoint: Sendable {
  private let invoke: @Sendable (WorkerCall) async throws -> JSONValue
  private let replies = OwnerReplies()

  public init(invoke: @escaping @Sendable (WorkerCall) async throws -> JSONValue) { self.invoke = invoke }

  public func endpoint(token: String, hello: WorkerHello) throws -> WorkerEndpoint {
    try WorkerEndpoint(token: token, hello: hello, invoke: invoke, upload: receive, download: send)
  }

  public func receive(_ call: WorkerCall, body: Body) async throws {
    guard call.operation == "owner.input", let operation = call.payload.stringValue else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid owner input stream")
    }
    try await replies.reserve(call.id, operation: operation)
    do {
      let payload = try await body.json(JSONValue.self)
      let result = try await invoke(WorkerCall(id: call.id, operation: operation, payload: payload))
      try Task.checkCancellation()
      await replies.complete(call.id, value: result)
    } catch {
      await replies.remove(call.id)
      throw error
    }
  }

  public func send(_ call: WorkerCall) async throws -> Body {
    if call.operation == "owner.output", let operation = call.payload.stringValue {
      return try await .json(replies.take(call.id, operation: operation))
    }
    return try await .json(invoke(call))
  }
}

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

private actor OwnerReplies {
  struct Entry { let operation: String; var value: JSONValue? }
  private var entries: [UUID: Entry] = [:]
  func reserve(_ id: UUID, operation: String) throws {
    guard entries[id] == nil else { throw WorkerProtocolError(.invalidMessage, message: "Duplicate owner input stream") }
    guard entries.count < 256 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many pending owner byte replies") }
    entries[id] = Entry(operation: operation)
  }

  func complete(_ id: UUID, value: JSONValue) { entries[id]?.value = value }
  func remove(_ id: UUID) { entries[id] = nil }
  func take(_ id: UUID, operation: String) throws -> JSONValue {
    guard let entry = entries[id], entry.operation == operation, let value = entry.value else {
      throw WorkerProtocolError(.invalidMessage, message: "Unknown owner byte reply")
    }
    entries[id] = nil
    return value
  }
}
