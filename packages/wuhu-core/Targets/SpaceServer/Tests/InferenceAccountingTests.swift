import ClaudeStream
import Foundation
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

  @Test func completedClaudeCallsSurviveMidTurnStopWithoutResultOrEOF() async throws {
    let folder = try ScratchFolder("claude-mid-turn-accounting")
    let file = folder.url.appendingPathComponent("space.sqlite")
    do {
      let space = try Space.open(file: file)
      let session = try await space.sessions.createSession(group: .shared, title: "claude", kind: .agent, createdBy: "owner", model: model)
      let json = """
      {"type":"assistant","timestamp":"2026-09-30T00:00:01Z","message":{"id":"msg1","model":"served","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":0}}}
      {"type":"assistant","timestamp":"2026-09-30T00:00:02Z","message":{"id":"msg1","model":"served","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":50}}}
      {"type":"assistant","timestamp":"2026-09-30T00:00:03Z","message":{"id":"msg2","model":"served","usage":{"input_tokens":5,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"output_tokens":20}}}
      {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool1","content":"done"}]}}
      {"type":"assistant","timestamp":"2026-09-30T00:00:04Z","message":{"id":"unfinished","model":"served","usage":{"input_tokens":5,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"output_tokens":0}}}
      """
      var reader = ClaudeStreamReader()
      var calls = ClaudeInferenceCalls()
      for frame in reader.read(Array((json + "\n").utf8)) {
        await recordClaudeInferences(calls.record(frame), space: space, session: session, model: model, logger: Logger(label: "test.claude"))
      }
    }
    let reopened = try Space.open(file: file)
    #expect(try await reopened.query("SELECT at, output FROM inferences ORDER BY at", as: .shared(.anonymous)).rows == [
      [.text("2026-09-30T00:00:01.000Z"), .integer(50)],
      [.text("2026-09-30T00:00:03.000Z"), .integer(20)],
    ])
  }

  @Test func claudeRowsUseLastAssistantUsageNotTurnResultAndFirstFrameTime() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "claude", kind: .agent, createdBy: "owner", model: model)
    let json = """
    {"type":"assistant","timestamp":"2026-09-30T00:00:01.123Z","message":{"id":"msg1","model":"first-served","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":0}}}
    {"type":"assistant","timestamp":"2026-09-30T00:00:02.456Z","message":{"id":"msg1","model":"last-served","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":50}}}
    {"type":"assistant","timestamp":"2026-09-30T00:00:03.789Z","message":{"id":"msg2","model":"last-served","usage":{"input_tokens":5,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"output_tokens":20}}}
    {"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":9999,"cache_read_input_tokens":9999,"cache_creation_input_tokens":9999,"output_tokens":9999}}
    """
    var reader = ClaudeStreamReader()
    var calls = ClaudeInferenceCalls()
    let frames = reader.read(Array((json + "\n").utf8))
    for frame in frames {
      await recordClaudeInferences(calls.record(frame), space: space, session: session, model: model, logger: Logger(label: "test.claude"))
    }
    await recordClaudeInferences(calls.drain(), space: space, session: session, model: model, logger: Logger(label: "test.claude"))
    #expect(try await space.query("SELECT at, model, served_model, input, cache_read, cache_write, output, reasoning, duration_ms, ttft_ms FROM inferences ORDER BY at", as: .shared(.anonymous)).rows == [
      [.text("2026-09-30T00:00:01.123Z"), .text("configured"), .text("last-served"), .integer(30), .integer(200), .integer(70), .integer(50), .null, .null, .null],
      [.text("2026-09-30T00:00:03.789Z"), .text("configured"), .text("last-served"), .integer(5), .integer(300), .integer(0), .integer(20), .null, .null, .null],
    ])
  }
}
