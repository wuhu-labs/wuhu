#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

struct OwnerRPC: Sendable {
  let client: WorkerClient
  func call<Request: Encodable & Sendable, Result: Decodable & Sendable>(_ operation: String, _ request: Request) async throws -> Result {
    let call = WorkerCall(operation: operation, payload: try ownerEncode(request))
    let metadata = try JSONEncoder().encode(call)
    let body: Body
    if metadata.count <= 12 << 10 {
      body = try await client.stream(call)
    } else {
      try await client.upload(WorkerCall(id: call.id, operation: "owner.input", payload: .string(operation)), body: .json(call.payload))
      body = try await client.stream(WorkerCall(id: call.id, operation: "owner.output", payload: .string(operation)))
    }
    let envelope: OwnerEnvelope
    do { envelope = try await body.json(OwnerEnvelope.self) }
    catch is CancellationError { throw CancellationError() }
    catch let error as WorkerProtocolError { throw error }
    catch { throw WorkerProtocolError(.invalidMessage, message: "Invalid owner byte reply") }
    if let fault = envelope.fault { throw try fault.error() }
    return try ownerDecode(Result.self, envelope.value)
  }
}

struct OwnerEnvelope: Codable, Sendable {
  let value: JSONValue
  let fault: OwnerFault?
}

func ownerEncode(_ value: some Encodable) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func ownerDecode<Value: Decodable>(_ type: Value.Type, _ value: JSONValue) throws -> Value {
  do { return try JSONDecoder().decode(type, from: Data(value.jsonString().utf8)) }
  catch { throw WorkerProtocolError(.invalidMessage, message: "Invalid owner operation payload") }
}

func ownerReply(_ body: () async throws -> JSONValue) async throws -> JSONValue {
  do { return try await ownerEncode(OwnerEnvelope(value: body(), fault: nil)) }
  catch is CancellationError { throw CancellationError() }
  catch let error as WorkerProtocolError { throw error }
  catch { return try ownerEncode(OwnerEnvelope(value: .null, fault: OwnerFault(error))) }
}
