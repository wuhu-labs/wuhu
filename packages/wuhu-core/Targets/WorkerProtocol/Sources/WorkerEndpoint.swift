#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import typealias Serve.Handler
import enum Serve.ServeError

public actor WorkerEndpoint {
  public static let controlBytes = 1 << 20
  public static let streamMetadataBytes = 12 << 10
  let token: String
  let hello: WorkerHello
  let invoke: @Sendable (WorkerCall) async throws -> JSONValue
  let upload: @Sendable (WorkerCall, Body) async throws -> Void
  let download: @Sendable (WorkerCall) async throws -> Body
  var agreement: WorkerAgreement?

  public init(
    token: String,
    hello: WorkerHello,
    invoke: @escaping @Sendable (WorkerCall) async throws -> JSONValue,
    upload: @escaping @Sendable (WorkerCall, Body) async throws -> Void,
    download: @escaping @Sendable (WorkerCall) async throws -> Body,
  ) throws {
    guard !token.isEmpty else { throw WorkerProtocolError(.invalidConfiguration, message: "Worker token is required") }
    self.token = token; self.hello = hello; self.invoke = invoke; self.upload = upload; self.download = download
  }

  public nonisolated var handler: Handler { { try await self.handle($0) } }

  func handle(_ request: Request) async throws -> Response {
    do {
      try Task.checkCancellation()
      guard (request.headers["Authorization"] ?? request.headers.sensitiveValues["authorization"]) == "Bearer " + token else {
        throw WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted")
      }
      guard request.method == .post else { throw WorkerProtocolError(.invalidMessage, message: "Worker messages require POST") }
      if request.url.path == "/worker/hello" {
        let peer = try await request.json(WorkerHello.self, upTo: Self.controlBytes)
        let agreed = try hello.negotiate(with: peer)
        if let agreement, agreement != agreed { throw WorkerProtocolError(.invalidMessage, message: "Worker agreement cannot change during an incarnation") }
        agreement = agreed
        return try .json(hello)
      }
      guard let agreement else { throw WorkerProtocolError(.notNegotiated, message: "Worker hello must succeed before execution") }
      switch request.url.path {
      case "/worker/call":
        guard agreement.capabilities.contains("owner.control.v1") else { throw WorkerProtocolError(.missingCapability, message: "owner.control.v1 was not negotiated") }
        let call = try await request.json(WorkerCall.self, upTo: Self.controlBytes)
        try call.validate()
        guard call.abi == agreement.abi else { throw WorkerProtocolError(.incompatibleABI, message: "Call does not match negotiated ABI") }
        let reply: WorkerReply
        do { reply = try await WorkerReply(id: call.id, result: invoke(call)) }
        catch is CancellationError { throw CancellationError() }
        catch { reply = WorkerReply(id: call.id, error: failure(error)) }
        try Task.checkCancellation()
        var body = try Body.json(reply)
        if body.contentLength! > Self.controlBytes {
          body = try .json(WorkerReply(id: call.id, error: .init(.capacityExceeded, message: "Worker control reply exceeds limit; use byte stream")))
        }
        return Response(status: .ok, body: body)
      case "/worker/upload", "/worker/download":
        guard agreement.capabilities.contains("owner.bytes.v1") else { throw WorkerProtocolError(.missingCapability, message: "owner.bytes.v1 was not negotiated") }
        guard let header = request.headers["X-Wuhu-Worker-Stream"], header.utf8.count <= (Self.streamMetadataBytes * 4 / 3 + 4),
              let metadata = Data(base64Encoded: header), metadata.count <= Self.streamMetadataBytes
        else {
          throw WorkerProtocolError(.invalidMessage, message: "Invalid worker byte stream metadata")
        }
        let call = try JSONDecoder().decode(WorkerCall.self, from: metadata)
        try call.validate()
        guard call.abi == agreement.abi else { throw WorkerProtocolError(.incompatibleABI, message: "Stream does not match negotiated ABI") }
        let body: Body
        if request.url.path == "/worker/upload" {
          try await upload(call, request.body ?? .empty)
          body = .empty
        } else {
          guard request.body == nil || request.body?.contentLength == 0 else {
            throw WorkerProtocolError(.invalidMessage, message: "Download requests cannot carry an upload body")
          }
          body = try await download(call)
        }
        try Task.checkCancellation()
        var headers: Headers = [.init("Connection")!: "close", .init("X-Wuhu-Worker-ABI")!: "1", .init("X-Wuhu-Worker-Call")!: call.id.uuidString]
        if let length = body.contentLength { headers[.init("Content-Length")!] = String(length) }
        return Response(status: .ok, headers: headers, body: body)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown worker message route")
      }
    } catch is CancellationError { throw CancellationError() }
    catch {
      var response = (try? Response.json(failure(error), status: .badRequest)) ?? .text("Invalid worker message", status: .badRequest)
      response.headers[.init("Connection")!] = "close"
      return response
    }
  }

  func failure(_ error: any Error) -> WorkerProtocolError {
    if let error = error as? WorkerProtocolError { return error }
    if case FetchError.bodyLimitExceeded = error { return .init(.capacityExceeded, message: "Worker message exceeds limit") }
    if case ServeError.requestBodyTooLarge = error { return .init(.capacityExceeded, message: "Worker message exceeds limit") }
    if error is DecodingError { return .init(.invalidMessage, message: "Invalid worker JSON message") }
    if case FetchError.transportFailure = error { return .init(.unavailable, message: "Worker connection failed") }
    return .init(.remoteFailure, message: "Worker operation failed")
  }
}
