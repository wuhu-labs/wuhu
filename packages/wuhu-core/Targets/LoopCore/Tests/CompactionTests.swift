import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SessionTools
import SpaceCore
import Testing
import WuhuAI

private let tightBudget = ContextBudget(maxInput: 1100, maxOutput: 100)

private func compactCall(
  summary: String,
  preReads: [String] = [],
  bookmark: String? = nil,
) -> ToolCall {
  var arguments: [String: JSONValue] = ["summary": .string(summary)]
  if !preReads.isEmpty { arguments["pre_reads"] = .array(preReads.map(JSONValue.string)) }
  if let bookmark { arguments["bookmark"] = .string(bookmark) }
  return .init(id: "call_c", name: "compact", arguments: .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
}

@Suite struct CompactionTests {
  @Test(arguments: ["", " \n "], [false, true])
  func emptySummaryIsATypedRefusalAndTheTurnContinues(summary: String, preRead: Bool) async throws {
    let call = compactCall(summary: summary, preReads: preRead ? ["/notes.md"] : [])
    #expect(throws: CompactArgumentsError.emptySummary) { _ = try decodeArguments(CompactArguments.self, from: call) }
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "compact misuse", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("compact", calls: [call]),
        { request in
          guard case let .toolResult(result)? = request.transcript.items.last,
                case let .failure(failure) = result.payload else { throw UnexpectedCall("missing compact refusal") }
          #expect(failure.message.contains("emptySummary"))
          #expect(failure.message.contains("non-empty summary"))
          return Fix.reply("continued after refusal")
        },
      ])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("compact refusal is followed by another inference") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 0)
      #expect(try await sessions.record(id).errorMessage == nil)
    }
  }

  @Test func `a model that stops past the hard threshold starts its next generation from a pointer`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("big turn", tokens: 900), Fix.replying("fresh start", tokens: 100)])
      try await runService(space, makeConfig(inference: { try await script($0) }, budget: tightBudget)) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("fresh turn landed") { try await sessions.settledWork(sid) && script.count == 2 }
      }
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(transcript.head?.summary == SessionPrompt.pointerSummary(session: sid, generation: 0))
      #expect(transcript.head?.summary.contains("/_/session-transcripts/\(sid.rawValue)/0.outline.txt") == true)
      #expect(transcript.items.count == 2, "nothing is kept: the head, then the fresh reply")
    }
  }

  @Test func aGenerationWithNothingToDropThatStillDoesNotFitErrors() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("big turn", tokens: 900), Fix.replying("the prompt alone is as big", tokens: 900)])
      try await runService(space, makeConfig(inference: { try await script($0) }, budget: tightBudget)) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 2)
      #expect(try await sessions.generationState(sid).generation == 1, "one pointer dropped the turn; a second would drop nothing")
      #expect(try await sessions.record(sid).errorMessage?.contains("nothing left to drop") == true)
    }
  }

  @Test func `contextLengthExceeded escalates to compaction instead of backoff`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.contextTooLong),
        Fix.replying("fits now"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        // The clock never advances: any backoff would hang this convergence.
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(try await sessions.generationState(sid).generation == 1)
      #expect(try await sessions.hydrate(sid).transcript.kernel.head?.summary == SessionPrompt.pointerSummary(session: sid, generation: 0))
      #expect(script.count == 2)
    }
  }

  @Test func `bookmark and compact are kernel tools and rewind to the bookmark`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("marking", calls: [.init(id: "call_0", name: "bookmark", arguments: .object(["name": .string("b1")]))]),
        Fix.replying("explored a dead end"),
        Fix.replying("folding", calls: [compactCall(summary: "exploration notes", bookmark: "b1")]),
        Fix.replying("continuing"),
      ])
      // No executeTool: the executor must never see bookmark or compact.
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("explore"), to: sid)
        try await until("explored") {
          guard script.count >= 2 else { return false }
          return try await sessions.settledWork(sid)
        }
        try await service.enqueue(item: Fix.message("now compact"), to: sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      guard case let .generationHead(head) = transcript.items.first else {
        Issue.record("expected a generation head")
        return
      }
      #expect(head.summary == "exploration notes")

      // Kept verbatim: everything after the bookmark up to the compact call.
      #expect(transcript.keptCount == 3)
      guard case let .assistant(kept) = transcript.items[1] else {
        Issue.record("expected the explored turn kept")
        return
      }
      #expect(kept.content.contains(.text("explored a dead end")))
      guard case let .message(keptMessage) = transcript.items[2] else {
        Issue.record("expected the compact-triggering message kept")
        return
      }
      #expect(keptMessage.content.text == "now compact")
      guard case let .assistant(fresh) = transcript.items.last else {
        Issue.record("expected the continuation turn")
        return
      }
      #expect(fresh.content.contains(.text("continuing")))
      let hasBookmark = transcript.items.contains { item in
        if case .bookmark = item { return true } else { return false }
      }
      #expect(!hasBookmark)
    }
  }

  @Test func `a crash between compaction and first inference redoes the pre-reads wholesale`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.put(sid, input: Fix.message("hello"))
      _ = try await sessions.drainQueue(sid)
      _ = try await sessions.writeCompaction(
        sid,
        head: .init(
          id: UUID(),
          timestamp: anchor,
          summary: "pre-crash summary",
          snapshot: .init(preReads: ["space://a.md"]),
          runningWork: [],
        ),
        kept: nil,
      )

      let script = InferenceScript([Fix.replying("resumed")])
      let exec = ExecScript { call in
        switch call.name {
        case "read":
          return .read(.init(path: "space://a.md", revision: .journal(1), content: "body"))
        default:
          throw UnexpectedCall("executor saw \(call.name)")
        }
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      try await runService(space, config) { _ in
        try await sessions.look(sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(exec.calls.value.map(\.name) == ["read"])
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(script.attempts.value.first?.itemCount == 2)
      #expect(transcript.assistantEntries.count == 1)
    }
  }
}
