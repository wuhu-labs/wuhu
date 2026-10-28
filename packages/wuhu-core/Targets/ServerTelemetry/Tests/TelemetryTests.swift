import Dependencies
import InMemoryTracing
import ServerTelemetry
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import Testing
import Tracing

private struct Refused: Error {}

private func owner(_ session: String? = nil) -> SpanOwner {
  SpanOwner(session: session.map(SessionID.init(rawValue:)), group: GroupID(rawValue: "g"))
}

private func recorded(_ body: () async throws -> Void) async rethrows -> [FinishedInMemorySpan] {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: { try await body() }
  return tracer.finishedSpans
}

@Test func aRootStampsItsOwnerOnEverySpanUnderIt() async throws {
  let spans = await recorded {
    await traced(.turn, under: .root(owner("s"))) { turn in
      turn.set(.steps, 2)
      await traced(.tool) { tool in tool.conclude(.ok) }
      turn.conclude(.ok)
    }
  }
  let turn = try #require(spans.first { $0.operationName == "agent.turn" })
  let tool = try #require(spans.first { $0.operationName == "tool.call" })
  #expect(turn.parentSpanID == nil)
  #expect(tool.parentSpanID == turn.spanID)
  #expect(tool.traceID == turn.traceID)
  for span in spans {
    #expect(span.attributes.get("wuhu.session.id") == .string("s"))
    #expect(span.attributes.get("wuhu.group.id") == .string("g"))
    #expect(span.attributes.get("wuhu.outcome") == .string("ok"))
  }
  #expect(turn.attributes.get("wuhu.steps") == .int64(2))
}

@Test func aThrowingBodyEndsErroredWithoutItsErrorText() async throws {
  let spans = await recorded {
    await #expect(throws: Refused.self) {
      try await traced(.script, under: .root(owner())) { _ in throw Refused() }
    }
    await #expect(throws: CancellationError.self) {
      try await traced(.firing, under: .root(owner())) { _ in throw CancellationError() }
    }
  }
  let script = try #require(spans.first { $0.operationName == "script.run" })
  #expect(script.attributes.get("wuhu.outcome") == .string("failed"))
  #expect(script.attributes.get("wuhu.session.id") == nil)
  #expect(script.status == SpanStatus(code: .error))
  #expect(script.errors.isEmpty)
  let firing = try #require(spans.first { $0.operationName == "handler.firing" })
  #expect(firing.attributes.get("wuhu.outcome") == .string("cancelled"))
  #expect(firing.status == nil)
}

@Test func theFirstConclusionWinsAndCarriesTheProviderText() async throws {
  let spans = await recorded {
    await #expect(throws: Refused.self) {
      try await traced(.attempt, under: .root(owner())) { span in
        span.conclude(.errored, providerText: "upstream overloaded")
        throw Refused()
      }
    }
  }
  let attempt = try #require(spans.first)
  #expect(attempt.attributes.get("exception.message") == .string("upstream overloaded"))
  #expect(attempt.status == SpanStatus(code: .error, message: "upstream overloaded"))
}

@Test func aCacheExpectationLandsOnlyOnAttempts() async throws {
  let spans = await recorded {
    await traced(.inference, under: .root(owner())) { _ in
      await expectingCache(CacheExpectation(tokens: 1200, idleMs: 40)) {
        await traced(.attempt) { _ in }
        await traced(.tool) { _ in }
      }
    }
  }
  let attempt = try #require(spans.first { $0.operationName == "model.attempt" })
  #expect(attempt.attributes.get("wuhu.cache.expected_tokens") == .int64(1200))
  #expect(attempt.attributes.get("wuhu.cache.idle_ms") == .int64(40))
  #expect(spans.first { $0.operationName == "tool.call" }?.attributes.get("wuhu.cache.expected_tokens") == nil)
}

@Test func aSpanThatDoesNotRecordNeverEvaluatesItsValues() async {
  await withDependencies { $0.tracer = NoOpTracer() } operation: {
    await traced(.turn, under: .root(owner())) { span in
      #expect(!span.isRecording)
      span.set(.steps, { Issue.record("evaluated"); return 1 }())
      span.event(.drained) { _ in Issue.record("filled") }
    }
  }
}

@Test func theFirstMachineAToolReachesNamesIt() async throws {
  let spans = await recorded {
    reachedMachine(Machine(rawValue: "mc_outside"))
    await traced(.tool, under: .root(owner("s"))) { _ in
      await traced(.script) { _ in reachedMachine(Machine(rawValue: "mc_first")) }
      reachedMachine(Machine(rawValue: "mc_second"))
    }
  }
  #expect(spans.first { $0.operationName == "tool.call" }?.attributes.get("wuhu.machine") == .string("mc_first"))
  #expect(spans.first { $0.operationName == "script.run" }?.attributes.get("wuhu.machine") == nil)
}

@Test func aPropagatedParentContinuesTheCallersTraceUnderItsOwner() async throws {
  let tracer = InMemoryTracer()
  try await withDependencies { $0.tracer = tracer } operation: {
    #expect(TraceParent.headers.isEmpty)
    #expect(TraceParent.propagated([:], owner: owner()) == nil)
    var headers: [String: String] = [:]
    await traced(.tool, under: .root(owner("s"))) { _ in headers = TraceParent.headers }
    let parent = try #require(TraceParent.propagated(headers, owner: owner("relay")))
    await parent.run { stampingOwners(tracer).startSpan("machine.exchange", context: ServiceContext.current ?? .topLevel).end() }
  }
  let tool = try #require(tracer.finishedSpans.first { $0.operationName == "tool.call" })
  let exchange = try #require(tracer.finishedSpans.first { $0.operationName == "machine.exchange" })
  #expect(exchange.traceID == tool.traceID && exchange.parentSpanID == tool.spanID)
  #expect(exchange.attributes.get("wuhu.session.id") == .string("relay"))
  #expect(exchange.attributes.get("wuhu.group.id") == .string("g"))
}

private struct Machine: RawRepresentable {
  let rawValue: String
}
