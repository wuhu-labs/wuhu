import Logging
import Synchronization

/// swift-otel's diagnostics cut to its errors plus one warning per streak of failed exports and one per streak of ticks that
/// dropped spans: its own warnings can echo `OTEL_EXPORTER_OTLP_HEADERS`. The level stays `.debug` whatever `OTEL_LOG_LEVEL`
/// sets, because the batch processor's success line is a debug line, and every tick ends in it or its failure line.
struct TraceExportLog: LogHandler {
  let upstream: Logger
  private let streaks = Streaks()
  var metadata: Logger.Metadata = [:]

  var logLevel: Logger.Level {
    get { .debug }
    set {}
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    switch (event.level, event.message.description) {
    case (.warning, "Spans were dropped this iteration because queue was full"):
      if streaks.state.withLock({ $0.dropped() }) {
        let numbers = (event.metadata ?? [:]).compactMapValues { Int("\($0)").map { Logger.MetadataValue.string("\($0)") } }.filter { ["queue_size", "dropped_count"].contains($0.key) }
        upstream.warning("Trace spans are dropped while the export queue is full", metadata: numbers)
      }
    case (.debug, "Exported batch."):
      streaks.state.withLock { _ = $0.exported(failed: false) }
    case (.warning, "Failed to export batch."):
      if streaks.state.withLock({ $0.exported(failed: true) }) { upstream.warning("Trace export failed; spans are dropped until an export succeeds") }
    case let (level, _) where level >= .error:
      upstream.log(level: level, event.message, metadata: metadata.merging(event.metadata ?? [:]) { $1 }, source: event.source, file: event.file, function: event.function, line: event.line)
    default:
      break
    }
  }

  private final class Streaks: Sendable {
    let state = Mutex(State())
  }

  /// A tick logs its drops, if any, before its export's line; a tick without drops ends the dropping streak.
  private struct State {
    var failing = false
    var dropping = false
    var droppedThisTick = false

    /// Whether this starts a streak.
    mutating func dropped() -> Bool {
      droppedThisTick = true
      defer { dropping = true }
      return !dropping
    }

    /// Whether this starts a streak of failures.
    mutating func exported(failed: Bool) -> Bool {
      if !droppedThisTick { dropping = false }
      droppedThisTick = false
      defer { failing = failed }
      return failed && !failing
    }
  }
}
