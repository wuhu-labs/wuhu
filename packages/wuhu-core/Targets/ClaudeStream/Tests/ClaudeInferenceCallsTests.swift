@testable import ClaudeStream
import Foundation
import Testing

@Suite struct ClaudeInferenceCallsTests {
  private func frame(id: String, timestamp: String, output: Int, model: String = "served") throws -> ClaudeStreamFrame {
    let json = """
    {"type":"assistant","timestamp":"\(timestamp)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":\(output)}}}
    """
    let frame = ClaudeStreamFrame(line: Array(json.utf8)[...])
    guard case .assistant = frame else { throw ProbeFailure.missingAssistant }
    return frame
  }

  @Test func nextMessageCompletesLastUsageAndModelWithFirstTimestamp() throws {
    var calls = ClaudeInferenceCalls()
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 0), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:02Z", output: 50, model: "last-served"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    let rows = try calls.record(frame(id: "b", timestamp: "2026-09-30T00:00:03Z", output: 8), at: "2026-09-30T00:00:00.000Z")
    #expect(rows.map(\.id) == ["a"])
    #expect(rows[0].timestamp == "2026-09-30T00:00:01Z")
    #expect(rows[0].model == "last-served")
    #expect(rows[0].usage.outputTokens == 50)
    #expect(rows[0].usage.inputTokens == 30)
    #expect(rows[0].usage.cacheReadInputTokens == 200)
    #expect(rows[0].usage.cacheCreationInputTokens == 70)
    #expect(calls.drain().map(\.id) == ["b"])
    #expect(calls.drain().isEmpty)
  }

  @Test(arguments: ["user", "tool_result"]) func toolBoundaryCompletesCallBeforeTurnEnds(type: String) throws {
    var calls = ClaudeInferenceCalls()
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5), at: "2026-09-30T00:00:00.000Z")
    let json = """
    {"type":"\(type)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool1","content":"done"}]}}
    """
    #expect(calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...]), at: "2026-09-30T00:00:00.000Z").map(\.id) == ["a"])
    #expect(calls.drain().isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:02Z", output: 5), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.drain().isEmpty)
  }

  @Test func resultCompletesLastCallWithoutCountingResultUsage() throws {
    var calls = ClaudeInferenceCalls()
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5), at: "2026-09-30T00:00:00.000Z")
    let json = """
    {"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":9999,"cache_read_input_tokens":9999,"cache_creation_input_tokens":9999,"output_tokens":9999}}
    """
    let rows = calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...]), at: "2026-09-30T00:00:00.000Z")
    #expect(rows.map(\.id) == ["a"])
    #expect(rows[0].usage.outputTokens == 5)
    #expect(calls.drain().isEmpty)
  }

  @Test func unrelatedFramesDoNotCompleteCall() throws {
    var calls = ClaudeInferenceCalls()
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5), at: "2026-09-30T00:00:00.000Z")
    let json = #"{"type":"system","subtype":"unrelated"}"#
    #expect(calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...]), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.drain().map(\.id) == ["a"])
  }

  @Test func partialMessagesPersistFinalUsageAtCompletionOnlyOnce() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/partial-usage.jsonl")
    var reader = ClaudeStreamReader()
    let frames = reader.read(Array(try Data(contentsOf: fixture)))
    var calls = ClaudeInferenceCalls()
    var rows: [ClaudeInferenceCalls.Call] = []
    for (index, frame) in frames.enumerated() {
      let finished = calls.record(frame, at: "2026-09-30T00:00:00.000Z")
      switch index {
      case 10: #expect(finished.map(\.id) == ["msg-tool"])
      case 18: #expect(finished.map(\.id) == ["msg-late-assistant"])
      case 23: #expect(finished.map(\.id) == ["msg-final"])
      default: #expect(finished.isEmpty)
      }
      rows += finished
    }
    #expect(rows.map(\.usage.outputTokens) == [140, 75, 250])
    #expect(rows.map(\.usage.inputTokens) == [32, 5, 10])
    #expect(rows.map(\.usage.cacheReadInputTokens) == [210, 300, 400])
    #expect(rows.map(\.usage.cacheCreationInputTokens) == [75, 0, 0])
    #expect(rows.map(\.timestamp) == ["2026-09-30T08:00:01.000Z", "2026-09-30T08:00:03.000Z", "2026-09-30T08:00:04.000Z"])
    #expect(calls.drain().isEmpty)
    for frame in frames { #expect(calls.record(frame, at: "2026-09-30T00:00:00.000Z").isEmpty) }
    #expect(calls.drain().isEmpty)
  }

  private func stream(_ event: String, parent: String? = nil) -> ClaudeStreamFrame {
    let parent = parent.map { "\"\($0)\"" } ?? "null"
    let json = "{\"type\":\"stream_event\",\"parent_tool_use_id\":\(parent),\"event\":\(event)}"
    return ClaudeStreamFrame(line: Array(json.utf8)[...])
  }

  private func start(_ id: String, parent: String? = nil) -> ClaudeStreamFrame {
    stream("""
    {"type":"message_start","message":{"id":"\(id)","usage":{"input_tokens":30,"cache_read_input_tokens":200,"cache_creation_input_tokens":70,"output_tokens":1}}}
    """, parent: parent)
  }

  @Test func interleavedParentStreamsKeepTheirOwnCumulativeUsage() throws {
    var calls = ClaudeInferenceCalls()
    #expect(calls.record(start("a"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.record(start("b", parent: "tool1"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 1), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "b", timestamp: "2026-09-30T00:00:02Z", output: 1), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.record(stream(#"{"type":"message_delta","usage":{"output_tokens":50}}"#), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.record(stream(#"{"type":"message_delta","usage":{"output_tokens":80}}"#, parent: "tool1"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    let child = calls.record(stream(#"{"type":"message_stop"}"#, parent: "tool1"), at: "2026-09-30T00:00:00.000Z")
    #expect(child.map(\.id) == ["b"])
    #expect(child.first?.usage.outputTokens == 80)
    let root = calls.record(stream(#"{"type":"message_stop"}"#), at: "2026-09-30T00:00:00.000Z")
    #expect(root.map(\.id) == ["a"])
    #expect(root.first?.usage.outputTokens == 50)
  }

  @Test(arguments: [false, true]) func interruptedStreamEmitsCancelledPartialUsage(hasDelta: Bool) throws {
    var calls = ClaudeInferenceCalls()
    #expect(calls.record(start("a"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 1), at: "2026-09-30T00:00:00.000Z").isEmpty)
    if hasDelta {
      #expect(calls.record(stream(#"{"type":"message_delta","usage":{"input_tokens":32,"cache_read_input_tokens":210,"cache_creation_input_tokens":75,"output_tokens":40}}"#), at: "2026-09-30T00:00:00.000Z").isEmpty)
    }
    let row = try #require(calls.drain().first)
    #expect(row.id == "a")
    #expect(row.outcome == .cancelled)
    #expect(row.timestamp == "2026-09-30T00:00:01Z")
    #expect(row.model == "served")
    #expect(row.usage.inputTokens == (hasDelta ? 32 : 30))
    #expect(row.usage.cacheReadInputTokens == (hasDelta ? 210 : 200))
    #expect(row.usage.cacheCreationInputTokens == (hasDelta ? 75 : 70))
    #expect(row.usage.outputTokens == (hasDelta ? 40 : nil))
    #expect(calls.drain().isEmpty)
    #expect(calls.record(start("a"), at: "2026-09-30T00:00:02.000Z").isEmpty)
    #expect(calls.drain().isEmpty)
  }

  @Test(arguments: [false, true]) func streamsWithoutAssistantUseArrivalTimeAndNullableModel(stopped: Bool) throws {
    var calls = ClaudeInferenceCalls()
    #expect(calls.record(start("a"), at: "2026-09-30T00:00:01.123Z").isEmpty)
    if stopped {
      #expect(calls.record(stream(#"{"type":"message_delta","usage":{"output_tokens":80}}"#), at: "2026-09-30T00:00:02.000Z").isEmpty)
      #expect(calls.record(stream(#"{"type":"message_stop"}"#), at: "2026-09-30T00:00:03.000Z").isEmpty)
    }
    let row = try #require(calls.drain().first)
    #expect(row.id == "a")
    #expect(row.outcome == (stopped ? .ok : .cancelled))
    #expect(row.timestamp == "2026-09-30T00:00:01.123Z")
    #expect(row.model == nil)
    #expect(row.usage.inputTokens == 30)
    #expect(row.usage.cacheReadInputTokens == 200)
    #expect(row.usage.cacheCreationInputTokens == 70)
    #expect(row.usage.outputTokens == (stopped ? 80 : nil))
    #expect(calls.drain().isEmpty)
  }

  @Test func stoppedStreamWithoutOutputDeltaEmitsUnknownOutput() throws {
    var calls = ClaudeInferenceCalls()
    #expect(calls.record(start("a"), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 1), at: "2026-09-30T00:00:00.000Z").isEmpty)
    let row = try #require(calls.record(stream(#"{"type":"message_stop"}"#), at: "2026-09-30T00:00:02.000Z").first)
    #expect(row.outcome == .ok)
    #expect(row.usage.outputTokens == nil)
    #expect(calls.drain().isEmpty)
  }

  @Test func omittedStartCacheFieldsRetainAssistantUsage() throws {
    var calls = ClaudeInferenceCalls()
    #expect(calls.record(stream(#"{"type":"message_start","message":{"id":"a","usage":{"input_tokens":30,"output_tokens":1}}}"#), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 1), at: "2026-09-30T00:00:00.000Z").isEmpty)
    #expect(calls.record(stream(#"{"type":"message_delta","usage":{"output_tokens":80}}"#), at: "2026-09-30T00:00:00.000Z").isEmpty)
    let row = try #require(calls.record(stream(#"{"type":"message_stop"}"#), at: "2026-09-30T00:00:00.000Z").first)
    #expect(row.usage.inputTokens == 30)
    #expect(row.usage.cacheReadInputTokens == 200)
    #expect(row.usage.cacheCreationInputTokens == 70)
    #expect(row.usage.outputTokens == 80)
  }

  private enum ProbeFailure: Error { case missingAssistant }
}
