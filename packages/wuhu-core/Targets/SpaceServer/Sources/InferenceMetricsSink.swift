import Foundation
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import Logging

func inferenceMetricsSink(writer: InferenceMetricsWriter, logger: Logger) -> InferenceMetricsSink {
  InferenceMetricsSink { metric in
    await writer.append(metric.jsonLine())
    guard metric.outcome != .ok else { return }
    logger.notice("inference attempt failed", metadata: [
      "session": "\(metric.session.rawValue)",
      "provider": "\(metric.provider)",
      "model": "\(metric.model)",
      "outcome": "\(metric.outcome.rawValue)",
      "error": "\(metric.errorKind ?? "unknown")",
      "status": "\(metric.status.map(String.init) ?? "none")",
      "duration_ms": "\(metric.durationMs)",
    ])
  }
}

actor InferenceMetricsWriter {
  private let file: URL
  private let logger: Logger
  private var handle: FileHandle?
  private var warned = false

  init(folder: URL, logger: Logger) {
    file = folder.appendingPathComponent("logs/inference.jsonl")
    self.logger = logger
  }

  func append(_ line: String) {
    do {
      try openIfNeeded().write(contentsOf: Data(line.utf8))
      warned = false
    } catch {
      handle = nil
      if !warned {
        warned = true
        logger.warning("inference metrics write failed: \(file.path): \(error)")
      }
    }
  }

  func close() {
    try? handle?.close()
    handle = nil
  }

  private func openIfNeeded() throws -> FileHandle {
    if let handle { return handle }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let opened = try FileHandle(forWritingTo: file)
    try opened.seekToEnd()
    handle = opened
    return opened
  }
}
