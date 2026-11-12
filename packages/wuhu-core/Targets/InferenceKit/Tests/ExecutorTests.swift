import Clocks
import ControlledTime
import Credentials
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import JSONValue
import ModelProviders
import Scratch
import SessionDomain
import Synchronization
import Testing
import WuhuAI

private let textSSE = """
event: message_start
data: {"message":{"model":"claude-served","usage":{"input_tokens":10,"cache_read_input_tokens":4}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {}

"""

private final class RequestBox: Sendable {
  private let bodies = Mutex<[JSONValue]>([])
  var captured: [JSONValue] { bodies.withLock { $0 } }
  func append(_ body: JSONValue) { bodies.withLock { $0.append(body) } }
}

private func stubFetch(sse: String, into box: RequestBox) -> FetchClient {
  FetchClient { request in
    let data = try await request.body?.data() ?? Data()
    box.append(JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null)
    return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
  }
}

private let lines: [TranscriptLine] = [
  .init(at: Date(timeIntervalSinceReferenceDate: 0), key: "message:hello", message: .user(.init(content: [.text("hello")]))),
]

private let compactTool = Tool(
  name: "compact",
  description: "Fold the conversation.",
  parameters: .object(["type": .string("object"), "properties": .object([:])]),
)
private let echoTool = Tool(
  name: "echo",
  description: "Echo.",
  parameters: .object(["type": .string("object"), "properties": .object([:])]),
)

private func makeExecutor(
  provider: String = "deepseek",
  model: String = "deepseek-v4-pro",
  trace: AttemptTraceClient? = nil,
  metrics: InferenceMetricsSink = .noop,
) async throws -> InferenceExecutor {
  let catalog = try fixtureCatalog()
  return InferenceExecutor(
    session: SessionID("test-session-one"),
    model: try await catalog.resolve(.init(provider: provider, model: model, effort: "high"), session: SessionID("executor-tests")),
    systemPrompt: "You are a session.",
    tools: [echoTool, compactTool],
    trace: trace,
    metrics: metrics,
  )
}

private final class MetricBox: Sendable {
  private let value = Mutex<InferenceMetric?>(nil)
  func set(_ metric: InferenceMetric) { value.withLock { $0 = metric } }
  var metric: InferenceMetric? { value.withLock { $0 } }
}

// Advances a fixed step on every `now` read, so `clock.measure` around a stream
// pull returns a deterministic non-zero duration and successive measures order.
private final class SteppingClock: NonsendingClock, Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  let step: Duration
  private let ticks = Mutex(0)

  init(step: Duration = .milliseconds(1)) { self.step = step }

  var now: Instant {
    let count = ticks.withLock { value -> Int in value += 1; return value }
    return Instant(offset: step * count)
  }

  var minimumResolution: Duration { step }
  func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

private func run(
  _ executor: InferenceExecutor,
  sse: String,
  attemptID: UUID = UUID(2),
) async throws -> (reply: CompletedInference, requests: [JSONValue]) {
  let box = RequestBox()
  let reply = try await withDependencies {
    $0.fetch = stubFetch(sse: sse, into: box)
    $0.continuousClock = ImmediateClock()
  } operation: {
    try await executor.run(attemptID: attemptID, lines: lines)
  }
  return (reply, box.captured)
}

@Suite(.deterministicDependencies(clock: VirtualClock())) struct ExecutorTests {
  @Test func capacityMetricsKeepProviderCode() {
    for code in ["response_too_large", "websocket_message_too_large"] {
      let metric = InferenceMetric.classify(.capacityExceeded(code: code, message: "capacity", status: 429))
      #expect(metric.outcome == .httpError)
      #expect(metric.kind == code)
      #expect(metric.status == 429)
    }
  }

  @Test func payloadMetricsKeepTypedKinds() {
    for (error, kind) in [
      (InferenceError.requestTooLarge(limitBytes: 128 << 20), "requestTooLarge"),
      (.requestTooLargeAfterCompaction(limitBytes: 128 << 20), "requestTooLargeAfterCompaction"),
    ] {
      let classified = InferenceMetric.classify(error)
      #expect(classified.outcome == .httpError)
      #expect(classified.kind == kind)
      #expect(classified.status == 413)
    }
  }

  @Test func normalTurnCarriesEffortVerbatimAndNoForcing() async throws {
    let (reply, requests) = try await run(try await makeExecutor(), sse: textSSE)

    let body = try #require(requests.first?.object)
    #expect(body["tool_choice"] == nil)
    #expect(body["thinking"] == .object(["type": .string("enabled")]))
    #expect(body["output_config"] == .object(["effort": .string("high")]))
    #expect(body["max_tokens"] == .integer(32768))

    #expect(reply.metadata.usage?.totalTokens == 19)
  }

  @Test func completedRequestContextContainsOpeningThenUnmodifiedLineMessages() async throws {
    var executor = try await makeExecutor()
    executor.opening = ["first opening", "second opening"]
    let (reply, _) = try await run(executor, sse: textSSE)
    #expect(reply.context == Context(
      systemPrompt: executor.systemPrompt,
      messages: executor.opening.map { .user(.init(content: [.text($0)])) } + lines.map(\.message),
      tools: executor.tools,
    ))
  }

  @Test func attemptLogCapturesRequestAndRawSSE() async throws {
    let bytes = Mutex(Data())
    let opened = Mutex<[UUID]>([])
    let attemptID = UUID(5)
    let trace = AttemptTraceClient { id in
      opened.withLock { $0.append(id) }
      return AttemptTraceSink { chunk in bytes.withLock { $0.append(chunk) } }
    }
    let executor = try await makeExecutor(trace: trace)
    _ = try await run(executor, sse: textSSE, attemptID: attemptID)

    #expect(opened.withLock { $0 } == [attemptID])
    let logged = String(decoding: bytes.withLock { $0 }, as: UTF8.self)
    let parts = logged.split(separator: "\n\n", maxSplits: 1)
    let request = try #require(JSONValue.parse(String(parts[0])))
    #expect(request.object?["model"] == .string("deepseek-v4-pro"))
    #expect(logged.hasSuffix(textSSE))
  }

  @Test func emitsMetricLineForSuccessfulAttemptWithTTFTBeforeDuration() async throws {
    let box = MetricBox()
    let executor = try await makeExecutor(metrics: InferenceMetricsSink { box.set($0) })
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    _ = try await withDependencies {
      $0.fetch = stubFetch(sse: textSSE, into: RequestBox())
      $0.continuousClock = SteppingClock()
      $0.date = .constant(fixed)
    } operation: {
      try await executor.run(attemptID: UUID(2), lines: lines)
    }

    let metric = try #require(box.metric)
    #expect(metric.outcome == .ok)
    #expect(metric.provider == "deepseek")
    #expect(metric.model == "deepseek-v4-pro")
    #expect(metric.effort == "high")
    #expect(metric.usage?.totalTokens == 19)
    #expect(metric.servedModel == "claude-served")
    let ttft = try #require(metric.ttftMs)
    #expect(ttft <= metric.durationMs)
    #expect(metric.durationMs > 0)

    let line = metric.jsonLine()
    #expect(line.hasSuffix("\n"))
    let object = try #require(JSONValue.parse(String(line.dropLast()))?.object)
    #expect(object["outcome"] == .string("ok"))
    #expect(object["session"] == .string("test-session-one"))
    #expect(object["provider"] == .string("deepseek"))
    #expect(object["ts"] != nil)
    #expect(object["ttft_ms"] != nil)
    #expect(object["duration_ms"] != nil)
    #expect(object["tokens"]?.object?["total"] == .integer(19))
  }

  @Test func emitsTimeoutOutcomeForReadTimeoutFailure() async throws {
    let box = MetricBox()
    let executor = try await makeExecutor(metrics: InferenceMetricsSink { box.set($0) })

    await #expect(throws: (any Error).self) {
      try await withDependencies {
        $0.fetch = FetchClient { _ in throw FetchError.transportFailure(kind: .readTimeout) }
        $0.continuousClock = ImmediateClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
      } operation: {
        try await executor.run(attemptID: UUID(3), lines: lines)
      }
    }

    let metric = try #require(box.metric)
    #expect(metric.outcome == .timeout)
    #expect(metric.errorKind == "readTimeout")
    #expect(metric.ttftMs == nil)
  }

  @Test func failedCallRetainsReportedPartialUsageAndServedModel() async throws {
    let box = MetricBox()
    let executor = try await makeExecutor(metrics: InferenceMetricsSink { box.set($0) })
    let partial = """
    event: message_start
    data: {"message":{"model":"claude-partial","usage":{"input_tokens":10,"cache_read_input_tokens":40,"cache_creation_input_tokens":20}}}

    event: message_delta
    data: {"usage":{"output_tokens":5}}

    event: error
    data: {"error":{"type":"overloaded_error","message":"overloaded"}}

    """
    await #expect(throws: (any Error).self) {
      try await withDependencies {
        $0.fetch = stubFetch(sse: partial, into: RequestBox())
        $0.continuousClock = ImmediateClock()
      } operation: {
        try await executor.run(attemptID: UUID(4), lines: lines)
      }
    }
    let metric = try #require(box.metric)
    #expect(metric.outcome != .ok)
    #expect(metric.servedModel == "claude-partial")
    #expect(metric.usage?.uncachedInputTokens == 10)
    #expect(metric.usage?.cacheReadTokens == 40)
    #expect(metric.usage?.cacheWriteTokens == 20)
    #expect(metric.usage?.outputTokens == 5)
    #expect(metric.usage?.reasoningTokens == nil)
  }
}

extension ExecutorTests {
  @Test func noneOnlyAnthropicRouteEmitsNoThinkingWithoutReplayScope() async throws {
    let document = ModelsDocument(providers: ["portable": .init(
      dialect: .anthropic, baseURL: URL(string: "https://offline.test")!, opaqueReplay: ModelsDocument.OpaqueReplay.none,
      models: ["model": .init(maxInput: 10000, maxOutput: 1000, efforts: ["none"], defaultEffort: "none")],
    )])
    let resolved = try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey("fixture") })
      .resolve(.init(provider: "portable", model: "model", effort: "none"), session: .init("none-test"))
    #expect(resolved.replayScope == nil)
    let requests = RequestBox()
    let executor = InferenceExecutor(session: .init("none-test"), model: resolved, systemPrompt: "offline", tools: [])
    try await withDependencies { $0.fetch = stubFetch(sse: textSSE, into: requests) } operation: {
      let result = try await executor.run(attemptID: UUID(99), lines: lines)
      #expect(result.message.content.contains { if case .text = $0 { true } else { false } })
    }
    let body = try #require(requests.captured.first?.object)
    #expect(body["thinking"] == nil)
    #expect(body["output_config"] == nil)
  }
}

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

extension ExecutorTests {
  @Test func environmentOnlyFirstPartyAnthropicThinkingRunsWithTransientVerifiedScope() async throws {
    let name = "ENV_THINKING_REPLAY_TEST_API_KEY"
    let previous = ProcessInfo.processInfo.environment[name]
    setenv(name, "env-thinking-fixture", 1)
    defer {
      if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
    }
    let document = ModelsDocument(providers: ["env-thinking-replay-test": .init(
      dialect: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
      models: ["model": .init(maxInput: 10000, maxOutput: 1000, efforts: ["high"], defaultEffort: "high")],
    )])
    let catalog = ProviderCatalog(document: document, credentials: .environmentOnly)
    let specifier = ModelSpecifier(provider: "env-thinking-replay-test", model: "model", effort: "high")
    let session = SessionID("env-thinking-test")
    let resolved = try await catalog.resolve(specifier, session: session)
    #expect(resolved.replayScope != nil)
    #expect(try await catalog.resolve(specifier, session: session).replayScope == resolved.replayScope)
    let requests = RequestBox()
    let executor = InferenceExecutor(session: session, model: resolved, systemPrompt: "offline", tools: [])
    try await withDependencies { $0.fetch = stubFetch(sse: textSSE, into: requests) } operation: {
      _ = try await executor.run(attemptID: UUID(98), lines: lines)
    }
    #expect(requests.captured.first?.object?["thinking"]?.object?["type"] == .string("adaptive"))
    setenv(name, "env-thinking-replacement", 1)
    #expect(try await catalog.resolve(specifier, session: session).replayScope != resolved.replayScope)
  }
}

@Suite(.deterministicDependencies(clock: VirtualClock())) struct WarmingPrefixTests {
  @Test func ordinaryWarmingRenderRetainsByteIdenticalPreviousPrefix() async throws {
    let executor = try await makeExecutor()
    let box = RequestBox()
    try await withDependencies {
      $0.fetch = stubFetch(sse: textSSE, into: box)
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 100))
      $0.uuid = .incrementing
    } operation: {
      var warming = lines
      let reply = try await executor.run(attemptID: UUID(40), lines: warming)
      let entry = AssistantEntry(reply.message, id: UUID(40), at: Date(timeIntervalSince1970: 100), metadata: reply.metadata, replayBinding: nil, mint: { ToolCallID(UUID().uuidString) })
      warming += TranscriptItem.assistant(entry).lines(session: executor.session)
      warming += TranscriptItem.notification(.init(id: UUID(41), timestamp: Date(timeIntervalSince1970: 3400), kind: .context, subscriptionID: SubscriptionID("cache-warming"), content: .init(text: "<cache-warming-notice>Ignore if there is nothing to do.</cache-warming-notice>"))).lines(session: executor.session)
      _ = try await executor.run(attemptID: UUID(42), lines: warming)
      let before = try #require(box.captured.first?.object)
      let after = try #require(box.captured.last?.object)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for field in ["system", "tools"] {
        #expect(try encoder.encode(before[field]) == encoder.encode(after[field]))
      }
      let prefix = try #require(before["messages"]?.array)
      let messages = try #require(after["messages"]?.array)
      #expect(messages.count > prefix.count)
      #expect(try encoder.encode(prefix) == encoder.encode(Array(messages.prefix(prefix.count))))
      #expect(Array(warming.prefix(lines.count)) == lines)
    }
  }
}
