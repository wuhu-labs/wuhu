import ServerTelemetry
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
import Testing
import WorkerProtocol

@Test func negotiationIgnoresReleaseAndUnknownCapabilities() throws {
  let old = WorkerHello(capabilities: WorkerHello.baseline.union(["old.optional"]), release: "old")
  let new = WorkerHello(capabilities: WorkerHello.baseline.union(["new.optional"]), release: "new")
  #expect(try old.negotiate(with: new) == WorkerAgreement(abi: 1, capabilities: WorkerHello.baseline))
  #expect(throws: WorkerProtocolError(.incompatibleABI, message: "No supported execution ABI intersection (supported: 1)")) {
    try old.negotiate(with: WorkerHello(abis: [2], release: "old"))
  }
  #expect(throws: WorkerProtocolError.self) {
    try old.negotiate(with: WorkerHello(required: WorkerHello.baseline.union(["future"]), release: "new"))
  }
}

@Test func controlContractAndTypedFailure() async throws {
  let endpoint = try WorkerEndpoint(token: "private-incarnation", hello: .init(release: "parent"), invoke: { call in
    if call.operation == "fail" { throw WorkerProtocolError(.capacityExceeded, message: "bounded") }
    return call.payload
  }, upload: { _, body in try await body.discard() }, download: { _ in .string("bytes") })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "private-incarnation", control: fetch, bytes: fetch)
  await #expect(throws: WorkerProtocolError.self) { try await client.call(.init(operation: "echo")) }
  #expect(try await client.negotiate(.init(release: "worker")).abi == 1)
  #expect(try await client.call(.init(operation: "echo", payload: ["value": "hello"])) == ["value": "hello"])
  await #expect(throws: WorkerProtocolError(.capacityExceeded, message: "bounded")) { try await client.call(.init(operation: "fail")) }
  await #expect(throws: WorkerProtocolError.self) { try await client.call(.init(abi: 2, operation: "echo")) }
  let body = try await client.stream(.init(operation: "machine.output"))
  #expect(try await body.text() == "bytes")
}

@Test func admissionBeforeEffect() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in
    Issue.record("Unadmitted effect executed"); return .null
  }, upload: { _, _ in Issue.record("Unadmitted upload executed") }, download: { _ in Issue.record("Unadmitted stream executed"); return .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let wrong = try WorkerClient(socket: "/private/test.sock", token: "wrong", control: fetch, bytes: fetch)
  await #expect(throws: WorkerProtocolError(.unauthorized, message: "Worker incarnation is not admitted")) { try await wrong.negotiate(.init(release: "worker")) }
  let request = Request(url: URL(string: "http://owner/worker/call")!, method: .post, headers: RequestHeaders(values: ["Authorization": "Bearer token"]), body: try .json(WorkerCall(operation: "effect")))
  let response = try await endpoint.handler(request)
  #expect(try await response.json(WorkerProtocolError.self).code == .notNegotiated)
}

@Test func replyCorrelationAndDisconnectAreNotFallbacks() async throws {
  let wrongReply = FetchClient { request in
    if request.url.path == "/worker/hello" { return try .json(WorkerHello(release: "parent")) }
    return try .json(WorkerReply(id: UUID(), result: .null))
  }
  let unavailable = FetchClient { _ in throw WorkerProtocolError(.unavailable, message: "closed") }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: wrongReply, bytes: unavailable)
  _ = try await client.negotiate(.init(release: "worker"))
  await #expect(throws: WorkerProtocolError.self) { try await client.call(.init(operation: "echo")) }
  await #expect(throws: WorkerProtocolError(.unavailable, message: "closed")) { try await client.stream(.init(operation: "attempt.events")) }
}

@Test func boundedControlAndMalformedStreamMetadata() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in .null }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  let oversized = WorkerCall(operation: "oversized", payload: .string(String(repeating: "x", count: WorkerEndpoint.controlBytes)))
  await #expect(throws: WorkerProtocolError.self) { try await client.call(oversized) }
  await #expect(throws: WorkerProtocolError.self) { try await client.stream(oversized) }
  let request = Request(url: URL(string: "http://owner/worker/download")!, method: .post, headers: RequestHeaders(values: ["Authorization": "Bearer token", "X-Wuhu-Worker-Stream": "bad-base64"]))
  let response = try await endpoint.handler(request)
  #expect(try await response.json(WorkerProtocolError.self).code == .invalidMessage)
}

@Test func failedRenegotiationDoesNotChangeAdmission() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { $0.payload }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  await #expect(throws: WorkerProtocolError.self) {
    try await client.negotiate(.init(capabilities: WorkerHello.baseline.union(["added"]), required: ["added"], release: "worker"))
  }
  #expect(try await client.call(.init(operation: "echo", payload: "still admitted")) == "still admitted")
}

@Test func nullReplyRoundTripsAsPresentResult() async throws {
  let reply = WorkerReply(id: UUID(), result: .null)
  let decoded = try await Body.json(reply).json(WorkerReply.self)
  #expect(decoded == reply)
  #expect(decoded.result == .some(.null))
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in .null }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  #expect(try await client.call(.init(operation: "null")) == .null)
}

private enum BrokenResponse: Error { case disconnected }

@Test func bodyConsumptionMapsDisconnectButPreservesCancellation() async throws {
  for cancelled in [false, true] {
    let fetch = FetchClient { request in
      let stream = AsyncThrowingStream<Bytes, any Error> { continuation in
        continuation.finish(throwing: cancelled ? CancellationError() : BrokenResponse.disconnected)
      }
      if request.url.path == "/worker/hello" { return try .json(WorkerHello(release: "parent")) }
      let metadata = try #require(request.headers["X-Wuhu-Worker-Stream"])
      let call = try JSONDecoder().decode(WorkerCall.self, from: #require(Data(base64Encoded: metadata)))
      return Response(status: .ok, headers: [.init("X-Wuhu-Worker-ABI")!: "1", .init("X-Wuhu-Worker-Call")!: call.id.uuidString], body: .stream(stream))
    }
    let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
    _ = try await client.negotiate(.init(release: "worker"))
    let body = try await client.stream(.init(operation: "download"))
    do { _ = try await body.bytes(); Issue.record("Expected a body failure") }
    catch is CancellationError { #expect(cancelled) }
    catch let error as WorkerProtocolError { #expect(!cancelled); #expect(error.code == .unavailable) }
  }
  for route in ["/worker/hello", "/worker/call", "/worker/upload"] {
    let fetch = FetchClient { request in
      if route != request.url.path { return try .json(WorkerHello(release: "parent")) }
      let stream = AsyncThrowingStream<Bytes, any Error> { $0.finish(throwing: BrokenResponse.disconnected) }
      var headers = Headers()
      if request.url.path == "/worker/upload" {
        let metadata = try #require(request.headers["X-Wuhu-Worker-Stream"])
        let call = try JSONDecoder().decode(WorkerCall.self, from: #require(Data(base64Encoded: metadata)))
        headers[.init("X-Wuhu-Worker-ABI")!] = "1"; headers[.init("X-Wuhu-Worker-Call")!] = call.id.uuidString
      }
      return Response(status: .ok, headers: headers, body: .stream(stream))
    }
    let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
    do {
      _ = try await client.negotiate(.init(release: "worker"))
      if route == "/worker/call" { _ = try await client.call(.init(operation: "call")) }
      if route == "/worker/upload" { try await client.upload(.init(operation: "upload"), body: .empty) }
      Issue.record("Expected unavailable for \(route)")
    } catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
  }
}

private struct PrivateFailure: Error, CustomStringConvertible {
  var description: String { "private-token-and-database-path" }
}

@Test func endpointErrorsAreTypedStaticAndCancellationPropagates() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { call in
    if call.operation == "cancel" { throw CancellationError() }
    throw PrivateFailure()
  }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  await #expect(throws: CancellationError.self) { try await client.call(.init(operation: "cancel")) }
  await #expect(throws: WorkerProtocolError(.remoteFailure, message: "Worker operation failed")) { try await client.call(.init(operation: "private-failure")) }
  for path in ["/worker/hello", "/worker/call", "/worker/download"] {
    let headers = RequestHeaders(values: ["Authorization": "Bearer token", "X-Wuhu-Worker-Stream": Data("invalid-json".utf8).base64EncodedString()])
    let request = Request(url: URL(string: "http://owner" + path)!, method: .post, headers: headers, body: .string("invalid-json"))
    let response = try await endpoint.handler(request)
    #expect(try await response.json(WorkerProtocolError.self).code == .invalidMessage)
  }
}

@Test func oversizedReplyIsCorrelatedCapacityRefusal() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in
    .string(String(repeating: "x", count: WorkerEndpoint.controlBytes))
  }, upload: { _, body in try await body.discard() }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  let call = WorkerCall(operation: "large-reply")
  let response = try await endpoint.handler(Request(url: URL(string: "http://owner/worker/call")!, method: .post, headers: .init(values: ["Authorization": "Bearer token"]), body: .json(call)))
  #expect(response.status.code == 200)
  let reply = try await response.json(WorkerReply.self)
  #expect(reply.id == call.id)
  #expect(reply.error?.code == .capacityExceeded)
  await #expect(throws: WorkerProtocolError.self) { try await client.call(call) }
}

@Test func clientRefusesInvalidOrOversizedJSONResponsesWithTypedErrors() async throws {
  for path in ["/worker/hello", "/worker/call"] {
    for (status, text, code) in [(431, "", WorkerProtocolError.Code.invalidMessage), (200, "not-json", .invalidMessage), (200, String(repeating: "x", count: WorkerEndpoint.controlBytes + 1), .capacityExceeded)] {
      let fetch = FetchClient { request in
        if request.url.path == path { return Response(status: .init(code: status), body: .string(text)) }
        return try .json(WorkerHello(release: "parent"))
      }
      let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
      do {
        _ = try await client.negotiate(.init(release: "worker"))
        _ = try await client.call(.init(operation: "call"))
        Issue.record("Expected invalid response refusal")
      } catch let error as WorkerProtocolError { #expect(error.code == code) }
    }
  }
}

@Test func uploadAcknowledgementHasExplicitZeroLengthAfterConsumption() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in .null }, upload: { _, body in
    let text = try await body.text()
    #expect(text == "uploaded")
  }, download: { _ in .empty })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  let call = WorkerCall(operation: "upload")
  let metadata = try JSONEncoder().encode(call).base64EncodedString()
  let request = Request(url: URL(string: "http://owner/worker/upload")!, method: .post, headers: .init(values: ["Authorization": "Bearer token", "X-Wuhu-Worker-Stream": metadata]), body: .string("uploaded"))
  let response = try await endpoint.handler(request)
  #expect(response.headers[.init("Content-Length")!] == "0")
  #expect(response.headers[.init("X-Wuhu-Worker-Call")!] == call.id.uuidString)
  #expect(try await response.body.bytes().isEmpty)
}

@Test func traceContextCrossesControlAndByteBoundaries() async throws {
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { call in
    #expect(ServerTracing.context == call.traceContext)
    #expect(ServerTracing.context?.session == "s")
    return .null
  }, upload: { call, body in
    #expect(ServerTracing.context == call.traceContext)
    #expect(ServerTracing.context?.session == "s")
    try await body.discard()
  }, download: { call in
    #expect(ServerTracing.context == call.traceContext)
    #expect(ServerTracing.context?.session == "s")
    return .empty
  })
  let fetch = FetchClient { try await endpoint.handler($0) }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  _ = try await client.negotiate(.init(release: "worker"))
  try await ServerTracing.$emitter.withValue({ _ in }) {
    let turn = ServerSpan(.turn, session: "s", group: "g")
    try await ServerTracing.$context.withValue(turn.context) {
      _ = try await client.call(.init(operation: "test.control"))
      try await client.upload(.init(operation: "test.upload"), body: .empty)
      try await client.stream(.init(operation: "test.download")).discard()
    }
  }
  #expect(ServerTracing.context == nil)
}

@Test(arguments: ["/worker/hello", "/worker/call", "/worker/upload"])
func serverShutdownResponseIsUnavailableRatherThanMalformedProtocol(route: String) async throws {
  let fetch = FetchClient { request in
    if request.url.path == route { return .text("500 Internal Server Error\n", status: .internalServerError) }
    return try .json(WorkerHello(release: "parent"))
  }
  let client = try WorkerClient(socket: "/private/test.sock", token: "token", control: fetch, bytes: fetch)
  do {
    _ = try await client.negotiate(.init(release: "worker"))
    if route == "/worker/call" { _ = try await client.call(.init(operation: "call")) }
    if route == "/worker/upload" { try await client.upload(.init(operation: "upload"), body: .empty) }
    Issue.record("Server shutdown response was accepted")
  } catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
}
