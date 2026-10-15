#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import struct HTTPTypes.HTTPField
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import struct SessionTools.ScriptIdentityReply
import protocol SessionTools.ScriptOwnerClient
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

struct IdentityRequestSnapshot: Codable, Sendable {
  let url: URL
  let method: String
  let headers: [String: String]
  let sensitive: [String: String]
  let hasBody: Bool
  let length: Int64?
  let contentType: String?
  let session: SessionID
  init(_ request: Request, session: SessionID) {
    url = request.url; method = request.method.rawValue; headers = request.headers.values; sensitive = request.headers.sensitiveValues
    hasBody = request.body != nil; length = request.body?.contentLength; contentType = request.body?.contentType; self.session = session
  }

  func request(body: Body) throws -> Request {
    guard let method = Method(rawValue: method), validHeaders(headers), validHeaders(sensitive), Set(headers.keys.map { $0.lowercased() }).isDisjoint(with: sensitive.keys.map { $0.lowercased() }) else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid identity request snapshot")
    }
    return .init(url: url, method: method, headers: RequestHeaders(values: headers, sensitiveValues: sensitive), body: hasBody ? .stream(length: length, contentType: contentType, body.asyncBytes()) : nil)
  }
}

struct IdentityResponseSnapshot: Codable, Sendable {
  struct Header: Codable, Sendable { let name: String; let value: String }
  let status: Int?
  let headers: [Header]
  let length: Int64?
  let contentType: String?
  let protectedValues: [String]
  let fault: OwnerFault?
  init(_ reply: ScriptIdentityReply) {
    protectedValues = reply.protectedValues
    switch reply.response {
    case let .success(response):
      status = response.status.code; headers = response.headers.map { .init(name: $0.name.rawName, value: $0.value) }; length = response.body.contentLength; contentType = response.body.contentType; fault = nil
    case let .failure(error): status = nil; headers = []; length = nil; contentType = nil; fault = OwnerFault(error)
    }
  }

  func response(body: Body) throws -> Response {
    guard let status, (100 ... 599).contains(status), headers.allSatisfy({ HTTPField.Name($0.name) != nil }) else { throw WorkerProtocolError(.invalidMessage, message: "Invalid identity response snapshot") }
    var fields = Headers()
    for header in headers { fields.append(HTTPField(name: HTTPField.Name(header.name)!, value: header.value)) }
    return .init(status: Status(code: status), headers: fields, body: .stream(length: length, contentType: contentType, body.asyncBytes()))
  }
}

private func validHeaders(_ headers: [String: String]) -> Bool {
  Set(headers.keys.map { $0.lowercased() }).count == headers.count && headers.keys.allSatisfy { HTTPField.Name($0) != nil }
}

actor ParentScriptIdentity {
  struct Entry { var reply: ScriptIdentityReply?; var metadataTaken = false; var bodyTaken = false }
  private var replies: [UUID: Entry] = [:]
  private var stopped = false
  func requireTransferable() throws {
    guard replies.isEmpty else { throw WorkerProtocolError(.unavailable, message: "Identity request resources cannot be transferred") }
  }

  func stop() { stopped = true; replies.removeAll() }
  func receive(_ call: WorkerCall, body: Body, owner: any ScriptOwnerClient) async throws {
    guard !stopped else { throw CancellationError() }
    guard replies[call.id] == nil else { throw WorkerProtocolError(.invalidMessage, message: "Duplicate identity request") }
    guard replies.count < 256 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many identity replies") }
    let input = try ownerDecode(IdentityRequestSnapshot.self, call.payload)
    let request = try input.request(body: body)
    replies[call.id] = .init()
    let reply = await owner.identityRequest(request, session: input.session)
    if Task.isCancelled { replies[call.id] = nil; throw CancellationError() }
    replies[call.id]?.reply = reply
  }

  func cancel(_ id: UUID) { replies[id] = nil }
  func metadata(_ id: UUID) throws -> IdentityResponseSnapshot {
    guard let entry = replies[id], let reply = entry.reply, !entry.metadataTaken else { throw WorkerProtocolError(.invalidMessage, message: "Unknown identity reply") }
    let result = IdentityResponseSnapshot(reply)
    if result.fault != nil { replies[id] = nil } else { replies[id]?.metadataTaken = true }
    return result
  }

  func body(_ id: UUID) throws -> Body {
    guard let entry = replies[id], entry.metadataTaken, !entry.bodyTaken, let reply = entry.reply, case let .success(response) = reply.response else { throw WorkerProtocolError(.invalidMessage, message: "Unknown identity response body") }
    replies[id]?.bodyTaken = true
    return .stream(length: response.body.contentLength, contentType: response.body.contentType, OwnerResourceBytes(body: response.body, finished: { await self.cancel(id) }))
  }
}

extension RemoteExecutionOwner {
  public func identityRequest(_ request: Request, session: SessionID) async -> ScriptIdentityReply {
    var protectedValues: [String] = []
    do {
      let id = UUID()
      let upload = try WorkerCall(id: id, operation: "script.identity-upload", payload: ownerEncode(IdentityRequestSnapshot(request, session: session)))
      let result: IdentityResponseSnapshot = try await withTaskCancellationHandler {
        try await rpc.client.upload(upload, body: request.body ?? .empty)
        return try await rpc.call("script.identity-response", StreamRequest(id: id))
      } onCancel: {
        Task { [rpc] in _ = try? await rpc.client.call(WorkerCall(operation: "owner.cancel", payload: ownerEncode(StreamRequest(id: id)))) }
      }
      protectedValues = result.protectedValues
      if let fault = result.fault { return .init(response: .failure(try fault.error()), protectedValues: protectedValues) }
      let body = try await rpc.resource("script.identity-body", id: id)
      return try .init(response: .success(result.response(body: body)), protectedValues: protectedValues)
    } catch { return .init(response: .failure(error), protectedValues: protectedValues) }
  }
}
