import Clocks
import Credentials
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import JSONValue
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

private let compactSSE = """
event: message_start
data: {"message":{"usage":{"input_tokens":50}}}

event: content_block_start
data: {"content_block":{"type":"tool_use","id":"call_1","name":"compact","input":{}}}

event: content_block_delta
data: {"delta":{"type":"input_json_delta","partial_json":"{\\"summary\\":\\"folded\\"}"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}

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

private let transcript = Transcript(items: [
  .direct(.init(
    id: UUID(0),
    sender: Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!),
    timestamp: Date(timeIntervalSinceReferenceDate: 0),
    content: .init(text: "hello"),
  )),
])

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
  hub: AttemptHub? = nil,
  trace: AttemptTraceClient? = nil,
  metrics: InferenceMetricsSink = .noop,
) async throws -> InferenceExecutor {
  let catalog = try fixtureCatalog()
  return InferenceExecutor(
    session: SessionID("test-session-one"),
    model: try await catalog.resolve(.init(provider: provider, model: model, effort: "high"), session: SessionID("executor-tests")),
    systemPrompt: "You are a session.",
    tools: [echoTool, compactTool],
    hub: hub,
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
private final class SteppingClock: Clock, Sendable {
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
  mode: InferenceMode,
  attemptID: UUID = UUID(2),
) async throws -> (reply: CompletedInference, requests: [JSONValue]) {
  let box = RequestBox()
  let reply = try await withDependencies {
    $0.fetch = stubFetch(sse: sse, into: box)
    $0.continuousClock = ImmediateClock()
  } operation: {
    try await executor.run(attemptID: attemptID, transcript: transcript, mode: mode)
  }
  return (reply, box.captured)
}

@Suite struct ExecutorTests {
  @Test(arguments: [true, false])
  func publicationFailureStillClosesTracePublishesTerminalAndRecordsMetric(failAtStart: Bool) async throws {
    let hub = AttemptHub()
    let metric = MetricBox()
    let closed = Mutex<[UUID]>([])
    let events = Mutex<[String]>([])
    var executor = try await makeExecutor(hub: hub, trace: .init(open: { _ in .init(append: { _ in }) }, close: { id in closed.withLock { $0.append(id) } }), metrics: .init { metric.set($0) })
    executor.eventSink = .init { _, event in
      switch event {
      case .started:
        events.withLock { $0.append("start") }
        if failAtStart { throw InferenceError.invalidInput(status: 503, body: "publication refused") }
      case .delta: throw InferenceError.invalidInput(status: 503, body: "publication refused")
      case .finished: events.withLock { $0.append("finish") }
      }
    }
    await #expect(throws: (any Error).self) { _ = try await run(executor, sse: textSSE, mode: .normal) }
    #expect(events.withLock { $0 } == ["start", "finish"])
    #expect(closed.withLock { $0 } == [UUID(2)])
    #expect(metric.metric != nil)
    #expect(hub.inFlight(session: SessionID("test-session-one")).isEmpty)
  }

  @Test func malformedModelMessageMetricKeepsTypedKind() {
    let classified = InferenceMetric.classify(.malformedModelMessage(message: "bad tool_use", reason: "invalid_tool_use_name"))
    #expect(classified.outcome == .httpError)
    #expect(classified.kind == "malformedModelMessage")
    #expect(classified.status == nil)
  }

  @Test func capacityMetricsKeepProviderCode() {
    for code in ["websocket_backpressure", "response_too_large", "websocket_message_too_large"] {
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
    let (reply, requests) = try await run(try await makeExecutor(), sse: textSSE, mode: .normal)

    let body = try #require(requests.first?.object)
    #expect(body["tool_choice"] == nil)
    #expect(body["thinking"] == .object(["type": .string("enabled")]))
    #expect(body["output_config"] == .object(["effort": .string("high")]))
    #expect(body["max_tokens"] == .integer(32768))

    #expect(reply.metadata.usage?.totalTokens == 19)
  }

  @Test func forcedCompactAppliesDeepSeekRecipeWithIdenticalToolList() async throws {
    let executor = try await makeExecutor()
    let normal = try await run(executor, sse: textSSE, mode: .normal)
    let forced = try await run(executor, sse: compactSSE, mode: .forcedCompact)

    let normalBody = try #require(normal.requests.first?.object)
    let forcedBody = try #require(forced.requests.first?.object)
    #expect(forcedBody["tool_choice"] == .object(["type": .string("tool"), "name": .string("compact")]))
    #expect(forcedBody["thinking"] == .object(["type": .string("disabled")]))
    #expect(forcedBody["output_config"] == nil)
    #expect(forcedBody["tools"] == normalBody["tools"])

    let calls = forced.reply.message.content.compactMap { block -> ToolCall? in
      if case let .toolCall(call) = block { return call }
      return nil
    }
    #expect(calls.map(\.name) == ["compact"])
  }

  @Test func forcedCompactKeepsAnthropicAdaptiveThinking() async throws {
    let executor = try await makeExecutor(provider: "anthropic", model: "claude-sonnet-5")
    let forced = try await run(executor, sse: compactSSE, mode: .forcedCompact)

    let body = try #require(forced.requests.first?.object)
    #expect(body["tool_choice"] == .object(["type": .string("tool"), "name": .string("compact")]))
    #expect(body["thinking"]?.object?["type"] == .string("adaptive"))
    #expect(body["output_config"] == .object(["effort": .string("high")]))
  }

  @Test func publishesAttemptLifecycleToHub() async throws {
    let hub = AttemptHub()
    let executor = try await makeExecutor(hub: hub)
    let attemptID = UUID(7)

    let events = hub.events(session: SessionID("test-session-one"))
    async let collected: [AttemptEvent] = {
      var seen: [AttemptEvent] = []
      for await event in events {
        seen.append(event)
        if case .finished = event { break }
      }
      return seen
    }()

    _ = try await run(executor, sse: textSSE, mode: .normal, attemptID: attemptID)

    let seen = await collected
    guard case .started(attemptID) = seen.first else {
      Issue.record("expected started first, got \(seen)")
      return
    }
    guard case let .finished(finishedID, .done(message, metadata)) = seen.last else {
      Issue.record("expected finished(done) last, got \(seen)")
      return
    }
    #expect(finishedID == attemptID)
    #expect(metadata.usage?.totalTokens == 19)
    #expect(!message.content.isEmpty)
    #expect(seen.count > 2)
    #expect(hub.inFlight(session: SessionID("test-session-one")).isEmpty)
  }

  @Test func lateJoinSnapshotTracksPartials() {
    let hub = AttemptHub()
    let session = SessionID("test-session-three")
    let attempt = UUID(4)
    hub.publish(session: session, .started(attemptID: attempt))
    #expect(hub.inFlight(session: session) == [attempt: AssistantMessage()])

    let partial = AssistantMessage(content: [.text("Hel")])
    hub.publish(session: session, .delta(
      attemptID: attempt,
      event: .textDelta(contentIndex: 0, delta: "Hel", partial: partial),
    ))
    #expect(hub.inFlight(session: session) == [attempt: partial])

    hub.publish(session: session, .finished(attemptID: attempt, outcome: .failed(reason: "cancelled")))
    #expect(hub.inFlight(session: session).isEmpty)
  }

  @Test func coldSessionIsASilentTopic() {
    let hub = AttemptHub()
    #expect(hub.inFlight(session: SessionID("test-session-nine")).isEmpty)
    hub.publish(session: SessionID("test-session-nine"), .finished(attemptID: UUID(8), outcome: .failed(reason: "x")))
    #expect(hub.inFlight(session: SessionID("test-session-nine")).isEmpty)
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
    _ = try await run(executor, sse: textSSE, mode: .normal, attemptID: attemptID)

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
      try await executor.run(attemptID: UUID(2), transcript: transcript, mode: .normal)
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
        try await executor.run(attemptID: UUID(3), transcript: transcript, mode: .normal)
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
        try await executor.run(attemptID: UUID(4), transcript: transcript, mode: .forcedCompact)
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
      let result = try await executor.run(attemptID: UUID(99), transcript: transcript, mode: .normal)
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
      _ = try await executor.run(attemptID: UUID(98), transcript: transcript, mode: .normal)
    }
    #expect(requests.captured.first?.object?["thinking"]?.object?["type"] == .string("adaptive"))
    setenv(name, "env-thinking-replacement", 1)
    #expect(try await catalog.resolve(specifier, session: session).replayScope != resolved.replayScope)
  }
}

@Suite struct WarmingPrefixTests {
  @Test func ordinaryWarmingRenderRetainsByteIdenticalPreviousPrefix() async throws {
    let executor = try await makeExecutor()
    let box = RequestBox()
    try await withDependencies {
      $0.fetch = stubFetch(sse: textSSE, into: box)
      $0.continuousClock = ImmediateClock()
      $0.date = .constant(Date(timeIntervalSince1970: 100))
      $0.uuid = .incrementing
    } operation: {
      var warming = transcript
      let reply = try await executor.run(attemptID: UUID(40), transcript: warming, mode: .normal)
      warming.appendAssistant(reply.message, id: UUID(40), metadata: reply.metadata)
      warming.append(.notification(.init(id: UUID(41), timestamp: Date(timeIntervalSince1970: 3400), kind: .context, subscriptionID: SubscriptionID("cache-warming"), content: .init(text: "<cache-warming-notice>Ignore if there is nothing to do.</cache-warming-notice>"))))
      _ = try await executor.run(attemptID: UUID(42), transcript: warming, mode: .normal)
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
      let normalBefore = await transcript.renderRequest(session: executor.session, systemPrompt: executor.systemPrompt, tools: executor.tools)
      let normalAfter = await warming.renderRequest(session: executor.session, systemPrompt: executor.systemPrompt, tools: executor.tools)
      #expect(try encoder.encode(normalBefore.messages) == encoder.encode(Array(normalAfter.messages.prefix(normalBefore.messages.count))))
    }
  }
}
