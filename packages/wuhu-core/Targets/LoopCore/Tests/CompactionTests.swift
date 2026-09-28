import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
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
  @Test func `hard pressure schedules a forced-compact inference and re-establishes state`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("big turn", tokens: 900),
        Fix.replying(
          "folding",
          calls: [compactCall(summary: "did big things", preReads: ["space://a.md"])],
          tokens: 950,
        ),
        Fix.replying("fresh start", tokens: 100),
      ])
      let exec = ExecScript { call in
        switch call.name {
        case "read":
          return .read(.init(path: "space://a.md", revision: .journal(1), content: "body"))
        default:
          throw UnexpectedCall("executor saw \(call.name)")
        }
      }
      let config = makeConfig(
        executeTool: { try await exec($0) },
        inference: { try await script($0) },
        budget: tightBudget,
      )

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        // The work axis flips no_work at the first big commit already; the
        // ladder converges only once the post-compaction turn has landed.
        try await until("fresh turn landed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(sid)
        }
      }

      // The kernel dispatched compact itself: the executor saw only the
      // re-establishment calls, and the forcing seam saw exactly one request.
      #expect(script.attempts.value.map(\.mode) == [.normal, .forcedCompact, .normal])
      #expect(exec.calls.value.map(\.name) == ["read"])

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      guard case let .generationHead(head) = transcript.items.first else {
        Issue.record("expected the new generation to start at its head")
        return
      }
      #expect(head.summary == "did big things")
      #expect(head.snapshot.preReads == ["space://a.md"])
      #expect(transcript.keptCount == 1)

      let provenances = transcript.items.compactMap { item -> ToolResultItem.Provenance? in
        guard case let .toolResult(result) = item else { return nil }
        return result.provenance
      }
      #expect(provenances == [.compactionReestablishment])
      guard case .assistant = transcript.items.last else {
        Issue.record("expected the fresh turn to end the transcript")
        return
      }
    }
  }

  @Test func `a forced turn that fails hard falls back to the out-of-band compactor`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("big turn", tokens: 900),
        Fix.failing(.invalidInput(status: 400, body: "too big")),
        Fix.replying("fresh start", tokens: 100),
      ])
      let compactor = CompactScript(.init(summary: "fallback summary"))
      let config = makeConfig(
        inference: { try await script($0) },
        compact: { try await compactor($0) },
        budget: tightBudget,
      )

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("fresh turn landed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(sid)
        }
      }

      #expect(script.attempts.value.map(\.mode) == [.normal, .forcedCompact, .normal])
      #expect(compactor.count.value == 1)
      let record = try await sessions.record(sid)
      #expect(record.work == .noWork)
      #expect(record.errorMessage == nil)

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      guard case let .generationHead(head) = transcript.items.first else {
        Issue.record("expected a generation head from the fallback")
        return
      }
      #expect(head.summary == "fallback summary")
    }
  }

  @Test func `a forced turn that refuses the call falls back too`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("big turn", tokens: 900),
        Fix.replying("I refuse to compact", tokens: 950),
        Fix.replying("fresh start", tokens: 100),
      ])
      let compactor = CompactScript(.init(summary: "fallback summary"))
      let config = makeConfig(
        inference: { try await script($0) },
        compact: { try await compactor($0) },
        budget: tightBudget,
      )

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("fresh turn landed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(sid)
        }
      }

      #expect(script.attempts.value.map(\.mode) == [.normal, .forcedCompact, .normal])
      #expect(compactor.count.value == 1)
    }
  }

  @Test func `contextLengthExceeded escalates to compaction instead of backoff`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.contextTooLong),
        Fix.replying("fits now"),
      ])
      let compactor = CompactScript(.init(summary: "squeezed"))
      let config = makeConfig(inference: { try await script($0) }, compact: { try await compactor($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        // The clock never advances: any backoff would hang this convergence.
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(compactor.count.value == 1)
      #expect(script.count == 2)
    }
  }

  @Test func `bookmark and compact are kernel tools and rewind to the bookmark`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("marking", calls: [.init(id: "call_0", name: "bookmark", arguments: .object(["name": .string("b1")]))]),
        Fix.replying("explored a dead end"),
        Fix.replying("folding", calls: [compactCall(summary: "exploration notes", bookmark: "b1")]),
        Fix.replying("continuing"),
      ])
      // No executeTool: the executor must never see bookmark or compact.
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("explore"), to: sid)
        try await until("explored") {
          guard script.count >= 2 else { return false }
          return try await sessions.settledWork(sid)
        }
        _ = try await service.enqueue(item: Fix.message("now compact"), to: sid)
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
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("hello"))
      _ = try await sessions.drainQueue(sid)
      _ = try await sessions.writeCompaction(
        sid,
        head: .init(
          id: UUID(),
          timestamp: anchor,
          summary: "pre-crash summary",
          snapshot: .init(preReads: ["space://a.md"]),
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

      try await runService(sessions, config) { _ in
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(exec.calls.value.map(\.name) == ["read"])
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(script.attempts.value.first?.itemCount == 2)
      #expect(transcript.assistantEntries.count == 1)
    }
  }

  @Test func `the compact command forces a compaction turn and injects its instructions`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("first turn"),
        Fix.replying("folding", calls: [compactCall(summary: "kept the build notes")]),
        Fix.replying("fresh start"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("first turn settled") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(sid)
        }
        try await sessions.requestCommand(sid, .compact(instructions: "keep the build notes"))
        try await until("the forced turn landed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(sid)
        }
      }

      #expect(script.attempts.value.map(\.mode) == [.normal, .forcedCompact, .normal])
      #expect(try await sessions.takeCommand(sid) == nil, "the loop consumes the standing command")

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      guard case let .generationHead(head) = transcript.items.first else {
        Issue.record("expected the compaction boundary to open the new generation")
        return
      }
      #expect(head.summary == "kept the build notes")
    }
  }

  @Test func `a compact command without instructions injects nothing`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let seen = TranscriptSpy()
      let script = InferenceScript([
        Fix.replying("first turn"),
        { request in
          seen.record(request.transcript)
          return Fix.reply("folding", calls: [compactCall(summary: "folded")])
        },
        Fix.replying("fresh start"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("first turn settled") {
          guard script.count == 1 else { return false }
          return try await sessions.settledWork(sid)
        }
        try await sessions.requestCommand(sid, .compact(instructions: nil))
        try await until("the forced turn landed") {
          guard script.count == 3 else { return false }
          return try await sessions.settledWork(sid)
        }
      }

      let forced = try #require(seen.first())
      let notifications = forced.items.compactMap { item -> SystemNotification? in
        guard case let .notification(notification) = item else { return nil }
        return notification
      }
      #expect(notifications.isEmpty, "a bare compact steers nothing into the context")
    }
  }
}

private final class TranscriptSpy: Sendable {
  private let seen = Mutex<[Transcript]>([])

  func record(_ transcript: Transcript) {
    seen.withLock { $0.append(transcript) }
  }

  func first() -> Transcript? {
    seen.withLock(\.first)
  }
}
