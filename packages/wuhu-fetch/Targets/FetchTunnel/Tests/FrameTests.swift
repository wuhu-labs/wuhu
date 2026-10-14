import Fetch
@testable import FetchTunnel
import Testing

@Test func frameRoundTrip() throws {
  let frame = Frame(kind: .chunk, id: UInt64.max, payload: Bytes([0, 255]))
  let decoded = try Frame.decode(frame.encoded(), limits: .init())
  #expect(decoded.id == frame.id)
  #expect(decoded.payload == frame.payload)
}

@Test func framingBoundsAndVersions() throws {
  for bytes in [Bytes(), Bytes([1]), Bytes([2, 1] + Array(repeating: 0, count: 8)), Bytes([1, 255] + Array(repeating: 0, count: 8))] {
    #expect(throws: TunnelError.corruptFraming) { try Frame.decode(bytes, limits: .init()) }
  }
  #expect(throws: TunnelError.corruptFraming) { try Frame.decode(Frame(kind: .chunk, id: 0).encoded(), limits: .init()) }
  #expect(throws: StreamFault.self) { try Frame.decode(Frame(kind: .chunk, id: 1, payload: Bytes([1, 2])).encoded(), limits: .init(chunkBytes: 1)) }
  #expect(throws: TunnelError.corruptFraming) { try Frame.decode(Frame(kind: .end, id: 1, payload: Bytes([1])).encoded(), limits: .init()) }
}

@Test func fairInterleavingAndAbortPriority() {
  var box = FairOutbox()
  box.enqueue([Frame(kind: .request, id: 1), Frame(kind: .chunk, id: 1), Frame(kind: .end, id: 1)], id: 1)
  box.enqueue([Frame(kind: .request, id: 2), Frame(kind: .chunk, id: 2), Frame(kind: .end, id: 2)], id: 2)
  #expect(box.next()?.id == 1)
  #expect(box.next()?.id == 2)
  box.remove(1)
  box.enqueue([Frame(kind: .abort, id: 1)], id: 1)
  #expect(box.next()?.id == 2)
  #expect(box.next()?.kind == .abort)
  #expect(box.next()?.kind == .end)
  #expect(box.next() == nil)
}

@Test func invalidLimitsFailWithoutTransportIO() {
  let transport = TunnelTransport(receive: { nil }, send: { _ in Issue.record("unexpected IO") }, abort: { Issue.record("unexpected abort") })
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(chunkBytes: 0)) }
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(streams: 0)) }
  #expect(throws: TunnelError.invalidConfiguration) { try BoundedWebSocketLimits(messageBytes: 0).validate() }
}

@Test func invalidHeadsAndRepeatedResponseFields() throws {
  var headers = Headers()
  headers.append(.init(name: .setCookie, value: "a=1"))
  headers.append(.init(name: .setCookie, value: "b=2"))
  let response = Head(Response(status: .ok, headers: headers), count: 0)
  #expect(try response.response(body: .init()).headers.map(\.value) == ["a=1", "b=2"])
  var bad = response
  bad.headers = [["bad name", "a"]]
  #expect(throws: TunnelError.protocolViolation) { try bad.fields() }
  bad.headers = [["x-header", "a\r\nb"]]
  #expect(throws: TunnelError.protocolViolation) { try bad.fields() }
  bad = response
  bad.status = 999
  #expect(throws: TunnelError.protocolViolation) { try bad.response(body: .init()) }
}

@Test func wireUsesNetworkByteOrder() {
  let frame = Frame(kind: .chunk, id: 0x0102_0304_0506_0708, payload: Bytes([0xFE]))
  #expect(Array(frame.encoded()) == [1, 3, 1, 2, 3, 4, 5, 6, 7, 8, 0xFE])
}

@Test func bodyMediaTypesSurviveWireHeads() throws {
  let json = try Body.json(["a": 1])
  let request = Request(url: .init(string: "https://example.test/")!, body: json)
  let head = Head(request, count: 7)
  let restored = try head.request(body: Bytes("{\"a\":1}".utf8))
  #expect(restored.headers["content-type"] == "application/json")
  #expect(restored.body?.contentType == "application/json")
  let response = Head(Response(status: .ok, body: json), count: 7)
  #expect(try response.response(body: .init()).headers[.contentType] == "application/json")
  #expect(try response.response(body: .init()).body.contentType == "application/json")
  var explicit = request
  explicit.headers["Content-Type"] = "custom/type"
  #expect(try Head(explicit, count: 7).request(body: .init()).body?.contentType == "custom/type")
  let typed = Response(status: .ok, headers: [.contentType: "override/type"], body: json)
  #expect(try Head(typed, count: 7).response(body: .init()).body.contentType == "override/type")
}

@Test func frameLimitsMustFitTransportMessages() async throws {
  let transport = TunnelTransport(maxMessageBytes: 64 << 10, receive: { Issue.record("unexpected receive"); return nil }, send: { _ in Issue.record("unexpected send") }, abort: { Issue.record("unexpected abort") })
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(headBytes: 64 << 10)) }
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: transport, limits: .init(chunkBytes: 64 << 10)) }
  await #expect(throws: TunnelError.invalidConfiguration) { try await Tunnel.serve(over: transport, limits: .init(headBytes: 64 << 10)) { _ in Response(status: .ok) } }
  _ = try Tunnel(over: transport, limits: .init(headBytes: (64 << 10) - 10, chunkBytes: (64 << 10) - 10))
  let tiny = TunnelTransport(maxMessageBytes: 137, receive: { nil }, send: { _ in }, abort: {})
  #expect(throws: TunnelError.invalidConfiguration) { try Tunnel(over: tiny, limits: .init(headBytes: 1, chunkBytes: 1)) }
}

@Test(arguments: [false, true])
func sensitiveContentTypeOverridesBodyDefaults(typedBody: Bool) throws {
  let body = typedBody ? try Body.json(["a": 1]) : Body.bytes(Bytes([42]))
  let request = Request(url: .init(string: "https://example.test/")!, headers: .init(sensitiveValues: ["Content-Type": "custom/sensitive"]), body: body)
  let restored = try Head(request, count: 1).request(body: Bytes([42]))
  #expect(restored.headers["content-type"] == "custom/sensitive")
  #expect(restored.body?.contentType == "custom/sensitive")
  #expect(request.headers.sensitiveValues["content-type"] == "custom/sensitive")
}
