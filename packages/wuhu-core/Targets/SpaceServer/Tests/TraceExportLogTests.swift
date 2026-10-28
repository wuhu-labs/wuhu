#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import Logging
import OTel
import Serve
import ServeNIO
import ServiceLifecycle
@testable import SpaceServer
import Synchronization
import Testing
import Tracing

@Suite struct TraceExportLogTests {
  @Test func aStreakOfFailedExportsLogsOneWarningAndASuccessEndsIt() async throws {
    let answers = Mutex<[Status]>([.badRequest, .badRequest, .ok, .badRequest])
    let (exports, export) = AsyncStream.makeStream(of: Void.self)
    let collector = try await ServeNIOServer.bind(port: 0, handler: { _ in
      defer { export.yield() }
      return Response(status: answers.withLock { $0.removeFirst() }, headers: [.contentType: "application/x-protobuf"])
    })
    let logs = WarningLog()
    var configuration = ServerTelemetryRuntime.configuration(version: "test", log: logs.logger)
    configuration.traces.otlpExporter.endpoint = "http://127.0.0.1:\(try #require(collector.localAddress?.port))/v1/traces"
    configuration.traces.batchSpanProcessor.scheduleDelay = .milliseconds(10)
    let (tracer, service) = try OTel.makeTracingBackend(configuration: configuration)
    let otel = ServiceGroup(services: [service], logger: Logger(label: "test"))
    try await withThrowingDiscardingTaskGroup { group in
      group.addTask { try await otel.run() }
      var exported = exports.makeAsyncIterator()
      for _ in 0 ..< 4 {
        tracer.startSpan("span").end()
        await exported.next()
      }
      await otel.triggerGracefulShutdown()
    }
    await collector.shutdown()
    #expect(logs.all.map(\.level) == [.warning, .warning] && logs.all.allSatisfy(\.metadata.isEmpty))
  }

  @Test func aStreakOfTicksThatDropSpansLogsOneWarningWithItsNumbersOnly() {
    let logs = WarningLog()
    let otel = Logger(label: "otel") { _ in TraceExportLog(upstream: logs.logger) }
    let drop = { (count: Int) in
      otel.warning("Spans were dropped this iteration because queue was full", metadata: ["queue_size": "2048", "dropped_count": "\(count)", "secret": "Bearer x"])
    }
    for ticks in [[3, 5], [7]] {
      for count in ticks {
        drop(count)
        otel.debug("Exported batch.")
      }
      otel.debug("Exported batch.")
    }
    #expect(logs.all.map(\.metadata) == [["queue_size": "2048", "dropped_count": "3"], ["queue_size": "2048", "dropped_count": "7"]])
  }
}

private final class WarningLog: Sendable {
  private let events = Mutex<[(level: Logger.Level, metadata: [String: String])]>([])
  var all: [(level: Logger.Level, metadata: [String: String])] { events.withLock { $0 } }
  var logger: Logger { Logger(label: "test") { _ in Handler(sink: self) } }

  private struct Handler: LogHandler {
    let sink: WarningLog
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
      sink.events.withLock { $0.append((event.level, (event.metadata ?? [:]).mapValues { "\($0)" })) }
    }
  }
}
