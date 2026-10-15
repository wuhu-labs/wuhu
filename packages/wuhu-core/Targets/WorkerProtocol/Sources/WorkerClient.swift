#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue

public actor WorkerClient {
  let base: URL
  let token: String
  let control: FetchClient
  let bytes: FetchClient
  var agreement: WorkerAgreement?

  public init(socket: String, token: String, control: FetchClient, bytes: FetchClient) throws {
    guard socket.hasPrefix("/"), !socket.utf8.contains(0), socket.utf8.count < 104,
          let encoded = socket.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
          let base = URL(string: "http+unix://" + encoded), !token.isEmpty
    else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Worker socket must be an absolute private Unix path shorter than 104 bytes; token is required")
    }
    self.base = base; self.token = token; self.control = control; self.bytes = bytes
  }

  public func negotiate(_ hello: WorkerHello) async throws -> WorkerAgreement {
    let response = try await fetch(control, path: "/worker/hello", body: .json(hello))
    let peer = try await decode(WorkerHello.self, response: response)
    let agreed = try hello.negotiate(with: peer)
    agreement = agreed
    return agreed
  }

  public func requireCapability(_ capability: String) throws {
    guard let agreement else { throw WorkerProtocolError(.notNegotiated, message: "Worker hello must succeed before execution") }
    guard agreement.capabilities.contains(capability) else { throw WorkerProtocolError(.missingCapability, message: "Missing execution capability: " + capability) }
  }

  public func call(_ call: WorkerCall) async throws -> JSONValue {
    try requireAgreement(call)
    let body = try Body.json(call)
    guard body.contentLength! <= WorkerEndpoint.controlBytes else { throw WorkerProtocolError(.capacityExceeded, message: "Worker control call exceeds limit; use byte stream") }
    let response = try await fetch(control, path: "/worker/call", body: body)
    return try await decode(WorkerReply.self, response: response).value(for: call)
  }

  public func upload(_ call: WorkerCall, body: Body) async throws {
    let response = try await transfer(call, path: "/worker/upload", body: body)
    try await response.body.discard()
  }

  public func stream(_ call: WorkerCall) async throws -> Body {
    try await transfer(call, path: "/worker/download", body: .empty).body
  }

  private func transfer(_ call: WorkerCall, path: String, body: Body) async throws -> Response {
    try requireAgreement(call)
    let metadata = try JSONEncoder().encode(call)
    guard metadata.count <= WorkerEndpoint.streamMetadataBytes else {
      throw WorkerProtocolError(.invalidMessage, message: "Worker stream metadata exceeds limit")
    }
    let response = try await fetch(bytes, path: path, body: body, metadata: metadata.base64EncodedString())
    guard response.headers[.init("X-Wuhu-Worker-ABI")!] == "1", response.headers[.init("X-Wuhu-Worker-Call")!] == call.id.uuidString else {
      throw WorkerProtocolError(.invalidMessage, message: "Invalid worker byte stream correlation")
    }
    return response
  }

  private nonisolated func decode<T: Decodable & Sendable>(_ type: T.Type, response: Response) async throws -> T {
    do { return try await response.json(type, upTo: WorkerEndpoint.controlBytes) }
    catch is CancellationError { throw CancellationError() }
    catch let error as WorkerProtocolError { throw error }
    catch FetchError.bodyLimitExceeded { throw WorkerProtocolError(.capacityExceeded, message: "Worker response exceeds limit") }
    catch { throw WorkerProtocolError(.invalidMessage, message: "Invalid worker JSON response") }
  }

  func requireAgreement(_ call: WorkerCall) throws {
    guard let agreement else { throw WorkerProtocolError(.notNegotiated, message: "Worker hello must succeed before execution") }
    guard agreement.abi == call.abi else { throw WorkerProtocolError(.incompatibleABI, message: "Call does not match negotiated ABI") }
    try call.validate()
  }

  func fetch(_ client: FetchClient, path: String, body: Body, metadata: String? = nil) async throws -> Response {
    var headers = RequestHeaders()
    headers.setSensitive("Authorization", "Bearer " + token)
    headers["Host"] = "localhost"
    if let metadata { headers["X-Wuhu-Worker-Stream"] = metadata }
    let response: Response
    do { response = try await client(Request(url: URL(string: base.absoluteString + path)!, method: .post, headers: headers, body: body)) }
    catch is CancellationError { throw CancellationError() }
    catch let error as WorkerProtocolError { throw error }
    catch { throw WorkerProtocolError(.unavailable, message: "Worker owner connection failed") }
    var mapped = response
    mapped.body = .stream(length: response.body.contentLength, contentType: response.body.contentType, WorkerResponseBytes(body: response.body))
    guard mapped.status.code == 200 else {
      throw try await decode(WorkerProtocolError.self, response: mapped)
    }
    return mapped
  }
}

private struct WorkerResponseBytes: AsyncSequence, Sendable {
  typealias Element = Bytes
  let body: Body
  struct AsyncIterator: AsyncIteratorProtocol {
    var base: BodyStream.AsyncIterator
    mutating func next() async throws -> Bytes? {
      do { return try await base.next() }
      catch is CancellationError { throw CancellationError() }
      catch let error as WorkerProtocolError { throw error }
      catch { throw WorkerProtocolError(.unavailable, message: "Worker owner connection failed while reading response") }
    }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: body.asyncBytes().makeAsyncIterator()) }
}
