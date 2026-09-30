@testable import ClaudeStream
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
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 0)).isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:02Z", output: 50, model: "last-served")).isEmpty)
    let rows = try calls.record(frame(id: "b", timestamp: "2026-09-30T00:00:03Z", output: 8))
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
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5))
    let json = """
    {"type":"\(type)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool1","content":"done"}]}}
    """
    #expect(calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...])).map(\.id) == ["a"])
    #expect(calls.drain().isEmpty)
    #expect(try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:02Z", output: 5)).isEmpty)
    #expect(calls.drain().isEmpty)
  }

  @Test func resultCompletesLastCallWithoutCountingResultUsage() throws {
    var calls = ClaudeInferenceCalls()
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5))
    let json = """
    {"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":9999,"cache_read_input_tokens":9999,"cache_creation_input_tokens":9999,"output_tokens":9999}}
    """
    let rows = calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...]))
    #expect(rows.map(\.id) == ["a"])
    #expect(rows[0].usage.outputTokens == 5)
    #expect(calls.drain().isEmpty)
  }

  @Test func unrelatedFramesDoNotCompleteCall() throws {
    var calls = ClaudeInferenceCalls()
    _ = try calls.record(frame(id: "a", timestamp: "2026-09-30T00:00:01Z", output: 5))
    let json = #"{"type":"system","subtype":"unrelated"}"#
    #expect(calls.record(ClaudeStreamFrame(line: Array(json.utf8)[...])).isEmpty)
    #expect(calls.drain().map(\.id) == ["a"])
  }

  private enum ProbeFailure: Error { case missingAssistant }
}
