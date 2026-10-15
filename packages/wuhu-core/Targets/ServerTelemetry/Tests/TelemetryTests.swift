import Clocks
import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import ServerTelemetry
import Synchronization
import Testing

@Test func boundedDropsAndRecoversFromDeadCollector() async {
  let buffer = SpanBuffer(capacity: 4)
  ServerTracing.$emitter.withValue({ buffer.append($0) }) {
    for _ in 0 ..< 20 { ServerSpan(.turn, session: "s", group: "g").finish() }
  }
  #expect(buffer.pending == 4)
  #expect(buffer.dropped == 16)
  struct Offline: Error {}
  await buffer.flush { _ in throw Offline() }
  #expect(buffer.pending == 0)
  #expect(buffer.dropped == 20)
  ServerTracing.$emitter.withValue({ buffer.append($0) }) { ServerSpan(.turn).finish() }
  await buffer.flush { spans in #expect(spans.count == 1) }
  #expect(buffer.pending == 0)
}

@Test func batchingContextAndContentFreeOTLP() async throws {
  let spans = Mutex<[FinishedSpan]>([])
  ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
    let turn = ServerSpan(.turn, session: "s", group: "g")
    ServerTracing.$context.withValue(turn.context) {
      ServerSpan(.inference).finish([.provider: "codex", .model: "sol", .effort: "high", .ttftMs: "10", .inputTokens: "12", .outputTokens: "4", .outcome: "ok"])
      let tool = ServerSpan(.tool)
      ServerTracing.$context.withValue(tool.context) {
        ServerSpan(.machine).finish([.machine: "devbox", .version: "v1", .kind: "exec", .exitCode: "0", .outcome: "ok"])
      }
      tool.finish([.tool: "exec", .bytesIn: "99", .bytesOut: "12", .outcome: "ok"])
    }
    turn.finish([.outcome: "ok"])
  }
  let snapshot = spans.withLock { $0 }
  let turn = try #require(snapshot.first { $0.name == .turn })
  let tool = try #require(snapshot.first { $0.name == .tool })
  #expect(snapshot.allSatisfy { $0.context.traceID == turn.context.traceID && $0.context.session == "s" && $0.context.group == "g" })
  #expect(snapshot.first { $0.name == .inference }?.parentSpanID == turn.context.spanID)
  #expect(tool.parentSpanID == turn.context.spanID)
  #expect(snapshot.first { $0.name == .machine }?.parentSpanID == tool.context.spanID)
  let exporter = try OTLPExporter(endpoint: URL(string: "http://collector:4318")!, fetch: FetchClient { request in
    #expect(request.url.absoluteString == "http://collector:4318/v1/traces")
    let text = try await request.body!.text()
    #expect(text.contains("wuhu-server"))
    #expect(text.contains("startTimeUnixNano"))
    #expect(!text.contains("arguments"))
    #expect(!text.contains("command"))
    return .text("{}")
  })
  try await exporter.export(snapshot)
}

@Test func disabledHasNoContext() {
  let span = ServerSpan(.turn)
  #expect(span.context == nil)
  span.finish()
}

@Test func slowCollectorCannotBackpressureProducers() async {
  let buffer = SpanBuffer(capacity: 4)
  let (entered, enter) = AsyncStream<Void>.makeStream()
  let (release, resume) = AsyncStream<Void>.makeStream()
  await ServerTracing.$emitter.withValue({ buffer.append($0) }) {
    ServerSpan(.turn).finish()
    let sender = Task {
      await buffer.flush { _ in
        enter.finish()
        for await _ in release {}
        throw OTLPExporter.ConfigurationError.collectorRejected
      }
    }
    for await _ in entered {}
    for _ in 0 ..< 100 { ServerSpan(.tool).finish() }
    #expect(buffer.pending == 4)
    #expect(buffer.dropped == 96)
    resume.finish()
    await sender.value
    #expect(buffer.pending == 0)
    #expect(buffer.dropped == 101)
  }
}

@Test func cancelledShutdownDrainsAllBatchesBeforeReturning() async {
  let buffer = SpanBuffer()
  let exported = BatchSizes()
  await ServerTracing.$emitter.withValue({ buffer.append($0) }) {
    for _ in 0 ..< 129 { ServerSpan(.tool).finish() }
    let shutdown = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await buffer.shutdown { batch in exported.values.withLock { $0.append(batch.count) } }
    }
    await shutdown.value
  }
  #expect(exported.values.withLock { $0 } == [64, 64, 1])
  #expect(buffer.pending == 0)
  #expect(buffer.dropped == 0)
}

@Test func shutdownDeadlineDropsAnUnavailableCollectorWithoutHanging() async throws {
  try await withDependencies {
    $0.installTimeControl()
  } operation: {
    @Dependency(\.timeControl) var time
    @Dependency(\.continuousClock) var clock
    let buffer = SpanBuffer(capacity: 4)
    ServerTracing.$emitter.withValue({ buffer.append($0) }) {
      for _ in 0 ..< 4 { ServerSpan(.tool).finish() }
    }
    let shutdown = Task { [clock] in await buffer.shutdown { _ in try await clock.sleep(for: .seconds(100)) } }
    try await time.asleep("shutdown deadline", dueIn: 2)
    try await time.asleep("blocked export", dueIn: 100)
    await time.advance(to: Date(timeIntervalSinceReferenceDate: 2))
    await shutdown.value
    #expect(buffer.pending == 0)
    #expect(buffer.dropped == 4)
  }
}

private final class BatchSizes: Sendable {
  let values = Mutex<[Int]>([])
}

@Test func stoppedPeriodicSenderDrainsItsSleepingQueue() async throws {
  try await withDependencies {
    $0.installTimeControl()
  } operation: {
    @Dependency(\.timeControl) var time
    let buffer = SpanBuffer()
    let exported = BatchSizes()
    let export: @Sendable ([FinishedSpan]) async throws -> Void = { batch in exported.values.withLock { $0.append(batch.count) } }
    let sender = Task { await buffer.run(export: export) }
    try await time.asleep("periodic sender", dueIn: 1)
    ServerTracing.$emitter.withValue({ buffer.append($0) }) { ServerSpan(.turn).finish() }
    sender.cancel()
    await sender.value
    #expect(exported.values.withLock { $0.isEmpty })
    await buffer.shutdown(export: export)
    #expect(exported.values.withLock { $0 } == [1])
    #expect(buffer.pending == 0)
  }
}
