#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import InMemoryTracing
import OperationClient
import OperationProtocol
import Synchronization
import Testing
import Tracing

private func inTrace<T>(_ tracer: InMemoryTracer, _ body: () async throws -> T) async rethrows -> T {
  let parent = tracer.startSpan("parent")
  defer { parent.end() }
  return try await ServiceContext.withValue(parent.context) { try await body() }
}

@Suite struct ExchangeSpanTests {
  @Test func describeIsOneClientSpanUnderTheCurrentOne() async throws {
    let wire = try Wire()
    let tracer = InMemoryTracer()
    let operations = try wire.operations(tracer: tracer)
    let parent = tracer.startSpan("parent")
    try await ServiceContext.withValue(parent.context) { _ = try await operations.describe("disk") }
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
    await operations.shutdown(); await wire.close()
  }

  @Test func anExchangeOutsideATraceStartsNoSpan() async throws {
    let wire = try Wire()
    let tracer = InMemoryTracer()
    let operations = try wire.operations(tracer: tracer)
    _ = try await operations.describe("disk")
    #expect(tracer.finishedSpans.isEmpty && tracer.performedContextInjections.isEmpty)
    await operations.shutdown(); await wire.close()
  }

  @Test func operationExchangesNameTheirOperationAndNoContent() async throws {
    let wire = try Wire()
    let tracer = InMemoryTracer()
    let operations = try wire.operations(tracer: tracer)
    let operation = try await inTrace(tracer) {
      let operation = try await operations.open(.init(scope: "test", key: "spans"), machine: "disk", start: emit(chunks: 1, size: 4, echo: true))
      try await operation.write("in", .init(data: Data("secret".utf8)), end: true)
      _ = try await drain(operation)
      #expect(try await operation.verdict().tag == .completed)
      return operation
    }
    await operations.shutdown(); await wire.close()
    let spans = tracer.finishedSpans.filter { $0.operationName == "machine.exchange" }
    let kinds = Set(spans.compactMap { span -> String? in
      guard case let .string(kind) = span.attributes.get("machine.exchange.kind") else { return nil }
      return kind
    })
    #expect(kinds.isSuperset(of: ["describe", "start", "poll", "input"]))
    let names: Set<String> = ["machine.id", "machine.exchange.kind", "operation.id", "http.response.status_code", "machine.exchange.head_ms", "machine.exchange.elapsed_ms", "wuhu.outcome", "error.type"]
    for span in spans {
      span.attributes.forEach { name, value in
        #expect(names.contains(name))
        #expect(!"\(value)".contains("secret"))
        #expect(!"\(value)".contains("/"))
      }
      if span.attributes.get("machine.exchange.kind") != .string("describe") {
        #expect(span.attributes.get("operation.id") == .string(operation.id.uuidString))
      }
    }
  }

  @Test func theRequestCarriesTheExchangeSpanContext() async throws {
    let wire = try Wire()
    let sent = Mutex<[String?]>([])
    wire.fault.withLock { $0 = (match: { request in sent.withLock { $0.append(request.headers["in-memory-span-id"]) }; return false }, fault: .hang) }
    let tracer = InMemoryTracer()
    let operations = try wire.operations(tracer: tracer)
    _ = try await inTrace(tracer) { try await operations.describe("disk") }
    let span = try #require(tracer.finishedSpans.first { $0.operationName == "machine.exchange" })
    #expect(sent.withLock { $0 } == [span.spanContext.spanID])
    await operations.shutdown(); await wire.close()
  }

  @Test func aFailedExchangeIsAnErrorSpanWithItsCode() async throws {
    let wire = try Wire()
    wire.set("disk", .fail)
    let tracer = InMemoryTracer()
    let operations = try wire.operations(tracer: tracer)
    do { _ = try await inTrace(tracer) { try await operations.describe("disk") }; Issue.record("Expected a transport failure") }
    catch let error as OperationError { #expect(error.code == .transport) }
    let span = try #require(tracer.finishedSpans.first { $0.operationName == "machine.exchange" })
    #expect(span.status?.code == .error)
    #expect(span.status?.message == nil)
    #expect(span.attributes.get("error.type") == .string("transport"))
    #expect(span.attributes.get("wuhu.outcome") == .string("errored"))
    #expect(span.attributes.get("http.response.status_code") == nil)
    await operations.shutdown(); await wire.close()
  }
}
