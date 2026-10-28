import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import HTTPTypes
import InferenceKit
import InMemoryTracing
import JSONValue
import ServerTelemetry
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Tracing

// One traced story: an agent runs a script, an exec on a machine and a task
// with a request; the task reports and the agent relays it. Every span names
// its session, the request links the two sessions' turns, the machine call
// carries the exec's context, and nothing said or run reaches a span.
@Test(.deterministicDependencies) func aTracedStoryLinksTurnsByTheirInputsAndRecordsNoContent() async throws {
  let tracer = InMemoryTracer()
  let machineCalls = Mutex<[String]>([])
  let (agent, task, machine) = try await withSessionDeps {
    try await withDependencies { $0.tracer = tracer } operation: {
      let story = try await Story(.direct)
      _ = try await story.worker()
      return try await story.running {
        let box = try await story.machine { request in
          if let span = request.headers[HTTPField.Name(InMemoryTracer.spanIDKey)!] { machineCalls.withLock { $0.append(span) } }
        }
        let agent = try await story.session()
        story.script([
          .call("run_script", ["source": "result('secret script')", "wait_seconds": 30]),
          .call("exec", ["machine": .string(box.id.rawValue), "cwd": .string(box.folder), "command": "echo secret output", "wait_seconds": 30]),
          .call("create_session", ["title": "secret task", "message": "secret brief", "expects_reply": true]),
          .say("secret waiting"),
          .say("secret relayed"),
        ], for: agent)
        story.script([
          .call("report") { transcript in
            let request = transcript.items.compactMap { if case let .message(message) = $0 { message.requestID } else { nil } }.first
            return ["request_id": .string(request?.rawValue ?? ""), "kind": "final", "content": "secret answer"]
          },
          .say("secret done"),
        ])
        try await story.say("secret ask", to: agent)
        try await until("the agent relays the final") { try await story.replies(agent).last == "secret relayed" }
        try await story.settled(agent)
        let task = try #require(try await story.store.transcript(agent).items.lazy.compactMap { item -> SessionID? in
          guard case let .toolResult(result) = item, case let .createSession(created) = result.payload else { return nil }
          return created.sessionID
        }.first)
        try await story.settled(task)
        return (agent, task, box.id)
      }
    }
  }

  let spans = tracer.finishedSpans
  func named(_ name: String) -> [FinishedInMemorySpan] { spans.filter { $0.operationName == name } }
  func string(_ span: FinishedInMemorySpan, _ key: String) -> String? {
    if case let .string(value) = span.attributes.get(key) { value } else { nil }
  }
  func strings(_ span: FinishedInMemorySpan, _ key: String) -> [String] {
    if case let .stringArray(value) = span.attributes.get(key) { value } else { [] }
  }
  func tool(_ name: String) throws -> FinishedInMemorySpan {
    try #require(named("tool.call").first { string($0, "gen_ai.tool.name") == name })
  }

  let turns = named("agent.turn")
  let agentTurns = turns.filter { string($0, "wuhu.session.id") == agent.rawValue }
  let taskTurns = turns.filter { string($0, "wuhu.session.id") == task.rawValue }
  #expect(agentTurns.count == 2 && taskTurns.count == 1, "\(turns.map { ($0.attributes.get("wuhu.session.id"), $0.attributes.get("wuhu.trigger")) })")
  let asked = try #require(agentTurns.first { string($0, "wuhu.trigger") == "message" })
  #expect(asked.parentSpanID == nil && strings(asked, "wuhu.input.message_ids").count == 1)
  #expect(asked.attributes.get("wuhu.queue.wait_ms") != nil)

  let script = try tool("run_script"), exec = try tool("exec"), create = try tool("create_session"), report = try tool("report")
  #expect([script, exec, create].allSatisfy { $0.parentSpanID == asked.spanID })
  #expect(named("script.run").first?.parentSpanID == script.spanID)
  #expect(string(exec, "wuhu.machine") == machine.rawValue)

  let request = try #require(string(create, "wuhu.request.id"))
  #expect(string(create, "wuhu.child.session") == task.rawValue)
  let child = try #require(taskTurns.first)
  #expect(string(child, "wuhu.trigger") == "request" && strings(child, "wuhu.input.request_ids") == [request])
  #expect(string(child, "wuhu.session.parent") == agent.rawValue)
  #expect(report.parentSpanID == child.spanID && string(report, "wuhu.request.id") == request)
  let relayed = try #require(agentTurns.first { $0.spanID != asked.spanID })
  #expect(strings(relayed, "wuhu.input.request_ids") == [request])

  let exchanges = named("machine.exchange")
  #expect(exchanges.contains { $0.parentSpanID == exec.spanID })
  #expect(machineCalls.withLock { $0 }.contains { call in exchanges.contains { $0.spanID == call && $0.parentSpanID == exec.spanID } })

  for span in spans {
    #expect(span.attributes.get("wuhu.session.id") != nil, "\(span.operationName)")
  }
  for span in spans {
    span.attributes.forEach { key, value in #expect(!"\(value)".contains("secret"), "\(span.operationName) \(key)") }
    #expect(!"\(span.events)\(String(describing: span.status))".contains("secret"), "\(span.operationName)")
  }
}

// The kernel's inference against a provider: each attempt sits under its
// inference with the provider, model and usage, and the next turn's attempt
// knows what cache the last one left. Tracing changes no byte of the
// Responses-dialect request bodies the provider is sent.
@Test func aKernelAttemptRecordsItsUsageAndTheCacheItExpects() async throws {
  let completed = #"data: {"type":"response.completed","response":{"id":"done","status":"completed","output":[{"type":"message","id":"m","role":"assistant","content":[{"type":"output_text","text":"secret reply"}]}],"usage":{"input_tokens":10,"output_tokens":2}}}"#
  let answer: @Sendable () -> Response = { Response(status: .ok, body: .bytes(Data((completed + "\n\n").utf8), contentType: "text/event-stream")) }
  let traced = try await kernelTurns(["secret first", "secret second"], traced: true, answer: answer)
  let untraced = try await kernelTurns(["secret first", "secret second"], traced: false, answer: answer)
  #expect(traced.bodies.count == 2 && traced.bodies == untraced.bodies)
  #expect(untraced.spans.isEmpty)

  let spans = traced.spans
  let inferences = spans.filter { $0.operationName == "agent.inference" }
  let attempts = spans.filter { $0.operationName == "model.attempt" }
  #expect(attempts.count == 2, "\(spans.map(\.operationName))")
  for attempt in attempts {
    #expect(inferences.contains { $0.spanID == attempt.parentSpanID })
    #expect(attempt.attributes.get("gen_ai.provider.name") == .string("testing"))
    #expect(attempt.attributes.get("gen_ai.request.model") == .string("test-model"))
    #expect(attempt.attributes.get("gen_ai.usage.input_tokens") == .int64(10))
    #expect(attempt.attributes.get("gen_ai.usage.output_tokens") == .int64(2))
    #expect(attempt.attributes.get("wuhu.inference.id") != nil)
    #expect(attempt.attributes.get("wuhu.outcome") == .string("ok"))
  }
  #expect(attempts.first?.attributes.get("wuhu.cache.expected_tokens") == nil)
  #expect(attempts.last?.attributes.get("wuhu.cache.expected_tokens") == .int64(10))
  #expect(attempts.last?.attributes.get("wuhu.cache.idle_ms") != nil)
  for span in spans {
    span.attributes.forEach { key, value in #expect(!"\(value)".contains("secret"), "\(span.operationName) \(key)") }
  }
}

// A provider's refusal: its text reaches the attempt's span and nothing
// else; the space's `inferences` row and the metrics line keep the code.
@Test func aProviderRefusalKeepsItsTextOnTheSpanOnly() async throws {
  let run = try await kernelTurns(["secret ask"], traced: true) {
    Response(status: .badRequest, body: .bytes(Data(#"{"error":{"message":"secret refusal"}}"#.utf8), contentType: "application/json"))
  }
  let attempt = try #require(run.spans.first { $0.operationName == "model.attempt" })
  #expect(attempt.attributes.get("wuhu.outcome") == .string("errored"))
  #expect(attempt.attributes.get("error.type") == .string("invalidInput"))
  #expect(attempt.attributes.get("http.response.status_code") == .int64(400))
  guard case let .string(text)? = attempt.attributes.get("exception.message") else { Issue.record("no provider text"); return }
  #expect(text.contains("secret refusal"))
  let metric = try #require(run.metrics.first)
  #expect(InferenceRecord(metric).error == "invalidInput")
  #expect(metric.jsonLine().contains(#""error":"invalidInput""#) && !metric.jsonLine().contains("secret"))
}

private struct KernelRun {
  let spans: [FinishedInMemorySpan]
  let bodies: [Data]
  let metrics: [InferenceMetric]
}

/// One kernel session answering `messages` in turn against a scripted provider, with every id and time fixed so two runs
/// send the same bytes.
private func kernelTurns(_ messages: [String], traced: Bool, answer: @escaping @Sendable () -> Response) async throws -> KernelRun {
  let tracer = InMemoryTracer()
  let bodies = Mutex<[Data]>([])
  let metrics = Mutex<[InferenceMetric]>([])
  try await withSessionDeps {
    try await withDependencies {
      if traced { $0.tracer = tracer }
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(Seeded())
      $0.fetch = FetchClient { request in
        let body = try await request.body?.data() ?? Data()
        bodies.withLock { $0.append(body) }
        return answer()
      }
    } operation: {
      let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
      let harness = try await SessionHarness(
        assembledModels: models, credentialResolver: .bound { _ in .init(credential: .apiKey("key"), identityEpoch: "epoch") },
        metrics: InferenceMetricsSink { metric in metrics.withLock { $0.append(metric) } },
      )
      let id = try await harness.createSession(title: "secret title")
      try await harness.running {
        for (index, message) in messages.enumerated() {
          try await harness.deliver(message, to: id)
          try await until("turn \(index + 1) is accounted") { metrics.withLock { $0.count } == index + 1 }
          if traced { try await until("turn \(index + 1) ends") { tracer.finishedSpans.filter { $0.operationName == "agent.turn" }.count == index + 1 } }
        }
      }
    }
  }
  return KernelRun(spans: tracer.finishedSpans, bodies: bodies.withLock { $0 }, metrics: metrics.withLock { $0 })
}

private struct Seeded: RandomNumberGenerator {
  private var state: UInt64 = 1

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
