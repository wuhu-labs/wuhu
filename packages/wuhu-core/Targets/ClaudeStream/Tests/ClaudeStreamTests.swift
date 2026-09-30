@testable import ClaudeStream
import Foundation
import JSONValue
import Testing

@Suite struct ClaudeStreamTests {
  private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures")

  private func fixture(_ name: String) throws -> [UInt8] {
    Array(try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("\(name).jsonl")))
  }

  private func replay(_ bytes: [UInt8], chunkSize: Int) -> [ClaudeStreamFrame] {
    var reader = ClaudeStreamReader()
    var frames: [ClaudeStreamFrame] = []
    for start in stride(from: 0, to: bytes.count, by: chunkSize) {
      frames += reader.read(bytes[start ..< min(start + chunkSize, bytes.count)])
    }
    if let last = reader.finish() { frames.append(last) }
    return frames
  }

  private func lines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
    bytes.split(separator: UInt8(ascii: "\n"))
  }

  @Test(arguments: ["hook", "manual-compact", "auto-compact", "partial-usage"], [1, 23, 65536])
  func everyCapturedLineIsOneFrameAndMirrorEntriesAreTheLogBytes(_ name: String, _ chunkSize: Int) throws {
    let bytes = try fixture(name)
    let frames = replay(bytes, chunkSize: chunkSize)
    let lines = lines(bytes)
    #expect(frames.count == lines.count)
    if name != "partial-usage" { #expect(frames.contains { if case .initialization = $0 { true } else { false } }) }
    for (frame, line) in zip(frames, lines) {
      switch frame {
      case let .transcriptMirror(entries):
        #expect(!entries.isEmpty)
        let array = "[" + entries.map { JSONValue.object($0).jsonString() }.joined(separator: ",") + "]"
        #expect(line.firstRange(of: Array(array.utf8)) != nil)
      case .undecodable:
        Issue.record("captured line did not decode")
      default:
        break
      }
    }
  }

  @Test func initializationAndTurnResultCarryTheLoopFields() throws {
    let frames = replay(try fixture("hook"), chunkSize: 8192)
    let initialization = try #require(frames.compactMap { frame -> ClaudeStreamFrame.Initialization? in
      if case let .initialization(value) = frame { value } else { nil }
    }.first)
    #expect(initialization.version == "2.1.272")
    #expect(!initialization.sessionID.isEmpty)
    let result = try #require(frames.compactMap { frame -> ClaudeStreamFrame.TurnResult? in
      if case let .result(value) = frame { value } else { nil }
    }.last)
    #expect(result.outcome == .success)
    #expect(!result.isError)
    #expect(result.text?.isEmpty == false, "the result frame carries the turn's answer")
    let usage = try #require(result.usage)
    #expect(usage.cacheReadInputTokens > 0)
    #expect(usage.contextTokens == usage.inputTokens + usage.cacheReadInputTokens)
  }

  @Test(arguments: [("manual-compact", ClaudeStreamFrame.CompactBoundary.Trigger.manual), ("auto-compact", .auto)])
  func compactBoundaryFrame(_ name: String, _ trigger: ClaudeStreamFrame.CompactBoundary.Trigger) throws {
    let boundaries = replay(try fixture(name), chunkSize: 128).compactMap { frame -> ClaudeStreamFrame.CompactBoundary? in
      if case let .compactBoundary(value) = frame { value } else { nil }
    }
    #expect(boundaries.count == 1)
    #expect(boundaries.first?.trigger == trigger)
    #expect((boundaries.first?.preTokens ?? 0) > 0)
  }

  @Test func rateLimitEvent() {
    let frames = replay(Array("""
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.62,"resetsAt":1790000000},"session_id":"s"}
    {"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1790184600,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.33,"resetsAt":1790184600},"seven_day":{"utilization":0.55,"resetsAt":1790290800}}},"session_id":"s"}
    """.utf8), chunkSize: 5)
    let limits = frames.compactMap { frame -> ClaudeStreamFrame.RateLimit? in
      if case let .rateLimit(value) = frame { value } else { nil }
    }
    #expect(limits.map(\.status) == [.allowedWarning, .rejected, .allowed])
    #expect(limits.map(\.type) == [nil, nil, "five_hour"])
    #expect(limits.map(\.utilization) == [0.62, nil, nil])
    #expect(limits.map(\.resetsAt) == [1_790_000_000, nil, 1_790_184_600])
    #expect(limits.last?.windows == [
      .init(name: "five_hour", utilization: 0.33, resetsAt: 1_790_184_600),
      .init(name: "seven_day", utilization: 0.55, resetsAt: 1_790_290_800),
    ])
  }

  @Test(arguments: [
    #"{"type":"system","subtype":"init","session_id":"s","model":"m"}"#,
    #"{"type":"transcript_mirror","filePath":"p","entries":{}}"#,
    #"{"type":"transcript_mirror","filePath":"p","entries":[{"uuid":"a"},"b"]}"#,
    #"{"type":"result","subtype":"success"}"#,
    #"{"type":"result","is_error":false}"#,
  ])
  func framesTheLoopDependsOnAreMalformedNotOther(_ line: String) throws {
    let frames = replay(Array(line.utf8), chunkSize: 7)
    #expect(frames == [.malformed(try #require(JSONValue.parse(line)))])
  }

  @Test func resultKeepsUnknownOutcomesAndMissingUsage() {
    let frames = replay(Array("""
    {"type":"result","subtype":"error_new_kind","is_error":true}
    {"type":"result","subtype":"error_max_budget_usd","is_error":true,"usage":{"input_tokens":1}}
    """.utf8), chunkSize: 4)
    let results = frames.compactMap { frame -> ClaudeStreamFrame.TurnResult? in
      if case let .result(value) = frame { value } else { nil }
    }
    #expect(results.map(\.outcome) == [.unknown("error_new_kind"), .errorMaxBudget])
    #expect(results.map(\.isError) == [true, true])
    #expect(results.map(\.usage) == [nil, nil])
  }

  @Test(arguments: [
    #"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"scheduled","pre_tokens":1}}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"throttled"}}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","utilization":"high"}}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":"x"}}}}"#,
    #"{"type":"future_type","payload":{"a":1}}"#,
    #"{"type":"system","subtype":"future_subtype"}"#,
    #"["not","an","object"]"#,
  ])
  func changedOrUnknownShapesPassThrough(_ line: String) throws {
    let frames = replay(Array(line.utf8), chunkSize: 7)
    #expect(frames == [.other(try #require(JSONValue.parse(line)))])
  }

  @Test func nonJSONLinesAreKeptAsBytesAndBlankLinesSkipped() {
    let frames = replay(Array("{\"type\":\"x\"}\n\nnot json\r\n{\"type\":".utf8), chunkSize: 3)
    #expect(frames == [
      .other(["type": "x"]),
      .undecodable(Array("not json\r".utf8)),
      .undecodable(Array("{\"type\":".utf8)),
    ])
  }

  @Test func twoMegabyteMirrorEntryArrivesWhole() {
    let payload = String(repeating: "a", count: 2_100_000)
    let line = #"{"type":"transcript_mirror","filePath":"/tmp/s.jsonl","entries":[{"type":"user","uuid":"x","message":{"content":"\#(payload)"}}]}"#
    let frames = replay(Array(line.utf8) + [UInt8(ascii: "\n")], chunkSize: 32768)
    #expect(frames == [.transcriptMirror(entries: [["type": "user", "uuid": "x", "message": ["content": .string(payload)]]])])
  }
}
