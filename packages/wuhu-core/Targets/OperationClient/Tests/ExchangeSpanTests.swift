#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import InMemoryTracing
import enum JSONValue.JSONValue
@testable import OperationClient
import OperationProtocol
import Synchronization
import Testing
import Tracing

private func inTrace<T>(_ tracer: InMemoryTracer, _ body: () async throws -> T) async rethrows -> T {
  let parent = tracer.startSpan("parent")
  defer { parent.end() }
  return try await ServiceContext.withValue(parent.context) { try await body() }
}

final class ExchangeRequests: Sendable { let value = Mutex<[Request]>([]) }

struct ExchangeFixture: Sendable {
  let link: MachineLink
  let requests: ExchangeRequests

  init(tracer: any Tracer = NoOpTracer(), fail: Bool = false) {
    let sent = ExchangeRequests()
    requests = sent
    link = MachineLink(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { request in
      sent.value.withLock { $0.append(request) }
      if fail { throw OperationError(.transport) }
      return try Self.response(request)
    }, clock: .continuous, ids: { UUID() }, tracer: tracer)
  }

  static func response(_ request: Request) throws -> Response {
    var response = try Response.json(JSONValue.object(["ok": true]))
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
    return response
  }

  func send(_ exchange: MachineExchange, body: Body? = nil, correlation: UUID? = nil) async throws -> JSONValue {
    try await link.send(JSONValue.self, "disk", exchange, body: body, correlation: correlation, deadline: .seconds(5), limit: OperationLimits.responseBytes).result.get()
  }
}

@Suite struct ExchangeSpanTests {
  @Test func describeIsOneClientSpanUnderTheCurrentOne() async throws {
    let tracer = InMemoryTracer()
    let wire = ExchangeFixture(tracer: tracer)
    let parent = tracer.startSpan("parent")
    try await ServiceContext.withValue(parent.context) { _ = try await wire.send(.describe) }
    parent.end()
    let spans = tracer.finishedSpans.filter { $0.operationName == "machine.exchange" }
    #expect(spans.count == 1)
    let span = try #require(spans.first)
    #expect(span.kind == .client)
    #expect(span.traceID == parent.context.inMemorySpanContext?.traceID)
    #expect(span.parentSpanID == parent.context.inMemorySpanContext?.spanID)
    #expect(span.status == nil)
    #expect(span.attributes.get("machine.id") == .string("disk"))
    #expect(span.attributes.get("machine.exchange.kind") == .string("describe"))
    #expect(span.attributes.get("http.response.status_code") == .int64(200))
    #expect(span.attributes.get("machine.exchange.head_ms") != nil)
    #expect(span.attributes.get("machine.exchange.elapsed_ms") != nil)
    #expect(span.attributes.get("operation.id") == nil)
    #expect(span.attributes.get("wuhu.outcome") == .string("ok"))
    #expect(span.attributes.get("error.type") == nil)
    await wire.link.taskScope.close()
  }

  @Test func anExchangeOutsideATraceStartsNoSpan() async throws {
    let tracer = InMemoryTracer()
    let wire = ExchangeFixture(tracer: tracer)
    _ = try await wire.send(.describe)
    #expect(tracer.finishedSpans.isEmpty && tracer.performedContextInjections.isEmpty)
    await wire.link.taskScope.close()
  }

  @Test func operationExchangesNameTheirOperationAndNoContent() async throws {
    let tracer = InMemoryTracer()
    let wire = ExchangeFixture(tracer: tracer)
    let operation = UUID()
    try await inTrace(tracer) {
      _ = try await wire.send(.describe)
      _ = try await wire.send(.start(operation), body: .json(StartRequest(kind: "fixture.v1", input: ["path": "/secret"])))
      _ = try await wire.send(.input(operation, channel: "in"), body: .json(WriteRequest(offset: .zero, payload: .init(data: Data("secret".utf8)), end: true)))
      _ = try await wire.send(.poll(operation, query: [.init(name: "channel", value: "out"), .init(name: "after", value: "0")]))
      _ = try await wire.send(.stop(operation), body: .json(StopRequest(reason: "secret")))
    }
    await wire.link.taskScope.close()
    let spans = tracer.finishedSpans.filter { $0.operationName == "machine.exchange" }
    let kinds = Set(spans.compactMap { span -> String? in
      guard case let .string(kind) = span.attributes.get("machine.exchange.kind") else { return nil }
      return kind
    })
    #expect(kinds.isSuperset(of: ["describe", "start", "poll", "input", "stop"]))
    let names: Set<String> = ["machine.id", "machine.exchange.kind", "operation.id", "http.response.status_code", "machine.exchange.head_ms", "machine.exchange.elapsed_ms", "wuhu.outcome", "error.type"]
    for span in spans {
      span.attributes.forEach { name, value in
        #expect(names.contains(name))
        #expect(!"\(value)".contains("secret"))
        #expect(!"\(value)".contains("/"))
      }
      if span.attributes.get("machine.exchange.kind") != .string("describe") {
        #expect(span.attributes.get("operation.id") == .string(operation.uuidString))
      }
    }
  }

  @Test func theRequestCarriesTheExchangeSpanContext() async throws {
    let tracer = InMemoryTracer()
    let wire = ExchangeFixture(tracer: tracer)
    _ = try await inTrace(tracer) { try await wire.send(.describe) }
    let span = try #require(tracer.finishedSpans.first { $0.operationName == "machine.exchange" })
    #expect(wire.requests.value.withLock { $0.map { $0.headers["in-memory-span-id"] } } == [span.spanContext.spanID])
    await wire.link.taskScope.close()
  }

  @Test func aFailedExchangeIsAnErrorSpanWithItsCode() async throws {
    let tracer = InMemoryTracer()
    let wire = ExchangeFixture(tracer: tracer, fail: true)
    do { _ = try await inTrace(tracer) { try await wire.send(.describe) }; Issue.record("Expected a transport failure") }
    catch let error as OperationError { #expect(error.code == .transport) }
    let span = try #require(tracer.finishedSpans.first { $0.operationName == "machine.exchange" })
    #expect(span.status?.code == .error)
    #expect(span.status?.message == nil)
    #expect(span.attributes.get("error.type") == .string("transport"))
    #expect(span.attributes.get("wuhu.outcome") == .string("errored"))
    #expect(span.attributes.get("http.response.status_code") == nil)
    await wire.link.taskScope.close()
  }
}
