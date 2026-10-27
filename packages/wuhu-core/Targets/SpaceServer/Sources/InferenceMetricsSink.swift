import ServerTelemetry
#if canImport(FoundationEssentials)
  import class Foundation.FileHandle
  import FoundationEssentials
#else
  import Foundation
#endif
import struct InferenceKit.InferenceMetric
import struct InferenceKit.InferenceMetricsSink
import Logging
import struct SpaceContract.GroupID
import struct SpaceCore.InferenceRecord
import class SpaceCore.Space

func inferenceMetricsSink(space: Space, writer: InferenceMetricsWriter, logger: Logger) -> InferenceMetricsSink {
  InferenceMetricsSink { metric in
    if ServerTracing.enabled {
      let group: String? = switch metric.payer {
      case let .session(session): try? await space.sessions.record(session).group.rawValue
      case let .observer(group, _): group
      }
      let span = ServerSpan(.inference, session: metric.session?.rawValue, group: group, start: metric.timestamp)
      var attributes: [SpanAttribute: String] = [.provider: metric.provider, .model: metric.model, .effort: metric.effort, .outcome: metric.outcome.rawValue]
      attributes[.ttftMs] = metric.ttftMs.map(String.init)
      attributes[.errorCode] = metric.errorKind
      attributes[.inputTokens] = metric.usage.map { String($0.uncachedInputTokens) }
      attributes[.outputTokens] = metric.usage.map { String($0.outputTokens) }
      attributes[.cacheReadTokens] = metric.usage.map { String($0.cacheReadTokens) }
      attributes[.cacheWriteTokens] = metric.usage.map { String($0.cacheWriteTokens) }
      attributes[.reasoningTokens] = metric.usage?.reasoningTokens.map(String.init)
      span.finish(attributes, end: metric.timestamp.addingTimeInterval(Double(metric.durationMs) / 1000))
    }
    await writer.append(metric.jsonLine())
    do {
      try await space.recordInference(InferenceRecord(metric))
    } catch {
      logger.error("inference database write failed", metadata: ["payer": "\(metric.payer)", "error": "\(error)"])
    }
    guard metric.outcome != .ok else { return }
    logger.notice("inference attempt failed", metadata: [
      "payer": "\(metric.payer)",
      "provider": "\(metric.provider)",
      "model": "\(metric.model)",
      "outcome": "\(metric.outcome.rawValue)",
      "error": "\(metric.errorKind ?? "unknown")",
      "status": "\(metric.status.map(String.init) ?? "none")",
      "duration_ms": "\(metric.durationMs)",
    ])
  }
}

extension InferenceRecord {
  init(_ metric: InferenceMetric) {
    self.init(
      id: metric.id, payer: metric.payer.record, at: metric.timestamp,
      provider: metric.provider, model: metric.model, servedModel: metric.servedModel, effort: metric.effort,
      input: metric.usage?.uncachedInputTokens, cacheRead: metric.usage?.cacheReadTokens,
      cacheWrite: metric.usage?.cacheWriteTokens, output: metric.usage?.outputTokens,
      reasoning: metric.usage?.reasoningTokens, outcome: metric.outcome.rawValue, error: metric.errorKind,
      durationMs: metric.durationMs, ttftMs: metric.ttftMs,
    )
  }
}

extension InferenceMetric.Payer {
  fileprivate var record: InferenceRecord.Payer {
    switch self {
    case let .session(session): .session(session)
    case let .observer(group, firing): .observer(group: GroupID(rawValue: group), firing: firing)
    }
  }
}

extension InferenceMetricsSink {
  /// Every inference into the space's `inferences` table and nothing else:
  /// what a server without the telemetry writer (tests) records.
  static func recording(in space: Space) -> InferenceMetricsSink {
    InferenceMetricsSink { metric in try? await space.recordInference(InferenceRecord(metric)) }
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
      _ = FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    let opened = try FileHandle(forWritingTo: file)
    try opened.seekToEnd()
    handle = opened
    return opened
  }
}
