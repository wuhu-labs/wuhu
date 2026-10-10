#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import Logging
import Scratch
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing
import WuhuAI

@Suite struct InferenceAccountingTests {
  private let model = ModelSpecifier(provider: "codex", model: "configured", effort: "high")

  @Test func kernelMetricWritesNormalizedRowAndUnchangedJSONLine() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "kernel", kind: .agent, createdBy: "owner", model: model)
    let folder = try ScratchFolder("inference-accounting")
    let logger = Logger(label: "test.inferences")
    let writer = InferenceMetricsWriter(folder: folder.url, logger: logger)
    let sink = inferenceMetricsSink(space: space, writer: writer, logger: logger)
    let metric = InferenceMetric(
      timestamp: Date(timeIntervalSince1970: 0), session: session, provider: model.provider,
      model: model.model, servedModel: "api-served", effort: model.effort, outcome: .ok,
      ttftMs: 80, durationMs: 1200,
      usage: .init(inputTokens: 224_721, outputTokens: 1000, cacheReadTokens: 222_976, reasoningTokens: 750, totalTokens: 225_721),
    )
    await sink.record(metric)
    await writer.close()
    #expect(try String(contentsOf: folder.url.appending(path: "logs/inference.jsonl"), encoding: .utf8) == metric.jsonLine())
    #expect(try await space.query("SELECT provider, model, served_model, input, cache_read, cache_write, output, reasoning, duration_ms, ttft_ms FROM inferences", as: .shared(.anonymous)).rows == [
      [.text("codex"), .text("configured"), .text("api-served"), .integer(1745), .integer(222_976), .integer(0), .integer(1000), .integer(750), .integer(1200), .integer(80)],
    ])
  }
}
