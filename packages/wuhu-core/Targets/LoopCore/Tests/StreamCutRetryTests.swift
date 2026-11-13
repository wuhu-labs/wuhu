import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
@testable import LoopCore
import ModelProviders
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct StreamCutRetryTests {
  @Test(arguments: [false, true])
  func cutStreamRetriesWithoutErrorOrPartialCommit(egressEvent: Bool) async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let document = ModelsDocument(providers: ["offline": .init(dialect: .responses, baseURL: URL(string: "https://example.test/v1")!, models: ["test": .init(maxInput: 1_001_000, maxOutput: 1000, efforts: ["low"], defaultEffort: "low")])])
      let catalog = ProviderCatalog(document: document, credentials: .init { _ in .apiKey("offline") })
      let requests = Box<[JSONValue]>([])
      let commits = Box<[UUID]>([])
      let provider = FetchClient { request in
        let body = try await request.body?.json(JSONValue.self) ?? .null
        let number = requests.withLock { $0.append(body); return $0.count }
        let cut = partialSSE + "\n" + (egressEvent ? cutErrorSSE : "")
        let sse = number == 1 ? cut : successfulSSE
        return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      }
      let step: InferenceScript.Step = { request in
        let sid = request.sessionID
        let resolved = try await catalog.resolve(.init(provider: "offline", model: "test", effort: "low"), session: sid)
        let executor = InferenceExecutor(session: sid, model: resolved, systemPrompt: "offline", tools: [])
        let result = try await executor.run(attemptID: request.attemptID, lines: request.lines)
        return InferenceReply(message: result.message, metadata: result.metadata, committed: { entry in commits.withLock { $0.append(entry.id) } })
      }
      let script = InferenceScript([step, step])
      var rng: any RandomNumberGenerator = SeededRNG(seed: 7)
      mirrorAllocationDraws(&rng)
      let delay = Double.random(in: 0 ... 1, using: &rng)
      let sid = try await withDependencies { $0.fetch = provider } operation: {
        let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
        let sid = try await sessions.createSession(group: .shared, title: "partial", kind: .agent, createdBy: "morgan", model: .test)
        try await runService(service) { service in
          try await service.enqueue(item: Fix.message("hello"), to: sid)
          try await until("failed attempt") { script.count == 1 }
          try await time.asleep("retry", dueIn: delay)
          #expect(try await sessions.record(sid).work != .errored)
          #expect(try await sessions.record(sid).errorMessage == nil)
          #expect(try await sessions.lines(sid).assistantLines.isEmpty)
          #expect(commits.value.isEmpty)
          try await time.wake("retry", after: delay)
          try await until("settled") { try await sessions.settledWork(sid) }
        }
        return sid
      }
      #expect(try await sessions.record(sid).work != .errored)
      #expect(try await sessions.record(sid).errorMessage == nil)
      #expect(requests.value.count == 2)
      #expect(requests.value[0] == requests.value[1])
      #expect(commits.value == [script.attempts.value[1].id])
      let entries = try await sessions.lines(sid).assistantLines
      #expect(entries.count == 1)
      #expect(entries[0].message.assistant?.content == [.text(TextContent(text: "done"))])
    }
  }
}

private let partialSSE = """
data: {"type":"response.output_item.added","item":{"type":"message","id":"msg"}}

data: {"type":"response.output_text.delta","delta":"discard me"}

data: {"type":"response.output_item.added","item":{"type":"function_call","id":"fc","call_id":"bad_call","name":"must_not_execute","arguments":"{}"}}

data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc","call_id":"bad_call","name":"must_not_execute","arguments":"{}"}}

"""

private let cutErrorSSE = """
data: {"type":"error","error":{"code":"upstream_stream_cut","message":"The model stream ended without a stop reason."}}

"""

private let successfulSSE = """
data: {"type":"response.output_item.added","item":{"type":"message","id":"msg"}}

data: {"type":"response.output_text.delta","delta":"done"}

data: {"type":"response.output_item.done","item":{"type":"message","id":"msg"}}

data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":1}}}

"""
