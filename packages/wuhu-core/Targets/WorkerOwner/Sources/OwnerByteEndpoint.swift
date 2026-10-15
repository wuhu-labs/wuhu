import struct Fetch.Body
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerCredentials
import class WorkerProtocol.WorkerEndpoint
import struct WorkerProtocol.WorkerHello
import struct WorkerProtocol.WorkerProtocolError
import struct WorkerProtocol.WorkerReceipt

public struct OwnerByteEndpoint: Sendable {
  private let invoke: @Sendable (WorkerCall) async throws -> JSONValue
  private let replies = OwnerReplies()
  private let journal = OwnerReceiptJournal()
  private let acknowledged: (@Sendable (WorkerCall) async -> Void)?
  private let customUpload: (@Sendable (WorkerCall, Body) async throws -> Bool)?
  private let customDownload: (@Sendable (WorkerCall) async throws -> Body?)?

  public init(invoke: @escaping @Sendable (WorkerCall) async throws -> JSONValue, upload: (@Sendable (WorkerCall, Body) async throws -> Bool)? = nil, download: (@Sendable (WorkerCall) async throws -> Body?)? = nil, acknowledged: (@Sendable (WorkerCall) async -> Void)? = nil) {
    self.invoke = invoke; customUpload = upload; customDownload = download; self.acknowledged = acknowledged
  }

  public func endpoint(token: String, hello: WorkerHello) throws -> WorkerEndpoint {
    endpoint(credentials: try WorkerCredentials(token: token), hello: hello)
  }

  public func endpoint(credentials: WorkerCredentials, hello: WorkerHello) -> WorkerEndpoint {
    WorkerEndpoint(credentials: credentials, hello: hello.retainingReplies(journal.identity), invoke: { call in
      if call.operation == "owner.ack" {
        if let admitted = try await journal.acknowledge(ownerDecode(WorkerReceipt.self, call.payload)) { await acknowledged?(admitted) }
        return .bool(true)
      }
      if call.operation == "owner.receipts" { return try await ownerEncode(journal.inventory()) }
      if call.operation == "owner.cancel" {
        let request = try ownerDecode(StreamRequest.self, call.payload)
        await cancel(request.id)
      }
      return try await invoke(call)
    }, upload: receive, download: send)
  }

  public func cancel(_ id: UUID) async { await journal.cancel(id); await replies.remove(id) }
  public func shutdown() async { await journal.stop() }

  public func receive(_ call: WorkerCall, body: Body) async throws {
    if try await customUpload?(call, body) == true { return }
    guard call.operation == "owner.input", let operation = call.payload.stringValue else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid owner input stream")
    }
    if call.receipt != nil {
      let payload = try await body.json(JSONValue.self, upTo: 64 << 20)
      let effect = WorkerCall(id: call.id, operation: operation, payload: payload, traceContext: call.traceContext, receipt: call.receipt)
      _ = try await journal.run(effect) { try await invoke(effect) }
      return
    }
    try await replies.reserve(call.id, operation: operation)
    do {
      let payload = try await body.json(JSONValue.self)
      let result = try await invoke(WorkerCall(id: call.id, operation: operation, payload: payload, traceContext: call.traceContext))
      try Task.checkCancellation()
      await replies.complete(call.id, value: result)
    } catch {
      await replies.remove(call.id)
      throw error
    }
  }

  public func send(_ call: WorkerCall) async throws -> Body {
    if let body = try await customDownload?(call) { return body }
    if call.operation == "owner.output", call.receipt != nil {
      return try await .json(journal.value(call))
    }
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
