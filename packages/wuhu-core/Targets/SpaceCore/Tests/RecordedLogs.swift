import Logging
import Synchronization

struct LogEntry: Sendable {
  let level: Logger.Level
  let message: String
  let metadata: [String: String]
}

final class RecordedLogs: Sendable {
  private let entries = Mutex<[LogEntry]>([])

  var all: [LogEntry] { entries.withLock { $0 } }

  var logger: Logger { Logger(label: "test") { _ in Handler(sink: self) } }

  private struct Handler: LogHandler {
    let sink: RecordedLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
      let merged = metadata.merging(event.metadata ?? [:]) { _, event in event }
      sink.entries.withLock {
        $0.append(LogEntry(level: event.level, message: event.message.description, metadata: merged.mapValues { "\($0)" }))
      }
    }
  }
}
