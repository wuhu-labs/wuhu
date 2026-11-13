#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceContract.PromptSession
import SpaceCore
import Testing
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1))) struct TranscriptTailTests {
  private static let reader = Principal(actor: .publicReader, group: .shared)

  /// A frame by its lines' keys.
  private enum Heard: Equatable {
    case reset(Int, [String])
    case lines(Int, [String])

    init(_ frame: TranscriptTail.Outgoing) {
      switch frame {
      case let .reset(generation, lines): self = .reset(generation, lines.map(\.key))
      case let .lines(generation, lines): self = .lines(generation, lines.map(\.key))
      }
    }
  }

  private func created(_ space: Space, in group: GroupID = .shared) async throws -> SessionID {
    try await space.sessions.createSession(group: group, title: "t", kind: .agent, createdBy: "morgan", model: .test)
  }

  /// Stores the prompt as main does during the generation's first inference.
  private static func storePrompt(_ store: SessionStore, _ id: SessionID) async throws {
    guard case let .pending(pending) = try await store.promptForInference(id) else { return }
    _ = try await store.storeInferencePrompt(id, for: pending, "the prompt", tools: [], session: PromptSession(try await store.record(id)))
    await store.noMail(id)
  }

  @Test func `a tail hears the generation, then each line in the order it was sent`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let repo = "machines://m1/repo"
      let script = InferenceScript([
        Fix.replying("reading", calls: [
          ToolCall(id: "call_0", name: "read", arguments: .object(["path": .string(repo + "/a")])),
          ToolCall(id: "call_1", name: "read", arguments: .object(["path": .string(repo + "/b")])),
        ]),
        Fix.replying("done"),
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.executeTool = { invocation in
        let payload = ToolResultPayload.read(.init(path: repo, revision: .journal(1), content: invocation.call.id))
        guard invocation.call.arguments == .object(["path": .string(repo + "/a")]) else { return ToolOutcome(payload: payload) }
        return ToolOutcome(payload: payload, context: ScopeContext(folders: [repo: repo], deliveredContext: nil, text: "repo manual"))
      }

      let execution = SessionExecution(space: space, loopConfig: config)
      let sid = try await created(space)
      try await runService(execution) { service in
        var tail = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        let frame = await tail.next().map(Heard.init)
        #expect(frame == .reset(0, []))
        try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("second assistant reply") {
          try await sessions.lines(sid).assistantLines.count == 2
        }
        let stored = try await sessions.lines(sid, generation: 0)
        var heard: [StoredTranscriptLine] = []
        while heard.count < stored.count, let frame = await tail.next() {
          guard case let .lines(0, lines) = frame else {
            Issue.record("heard \(frame)")
            return
          }
          heard += lines
        }
        #expect(heard == stored)
        #expect(heard.map { $0.key.prefix { $0 != ":" } } == ["message", "attempt", "call", "call", "subscription", "attempt"])
      }
    }
  }

  @Test func `the prompt reaches a live tail with the first reply only, and a tail that left off hears what it missed and the prompt lines again`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([Fix.replying("first"), Fix.replying("second")])
      let config = makeConfig(inference: { request in
        try await Self.storePrompt(sessions, request.sessionID)
        return try await script(request)
      })
      let execution = SessionExecution(space: space, loopConfig: config)
      let sid = try await created(space)
      try await runService(execution) { service in
        var live = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        var frame = await live.next().map(Heard.init)
        #expect(frame == .reset(0, []))

        try await service.enqueue(item: Fix.message("one", message: "m1"), to: sid)
        try await until("first reply") { try await sessions.settledWork(sid) && script.count == 1 }
        let first = try await sessions.lines(sid, generation: 0)
        let heardFirst = await hear(&live) { Self.keys($0).count >= first.count }.map(Self.keys) ?? []
        #expect(heardFirst.sorted() == first.map(\.key).sorted())
        #expect(heardFirst.prefix(2) == ["message:m1", "system"], "heard \(heardFirst)")
        let left = first.last!.position

        try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await until("second reply") { try await sessions.settledWork(sid) && script.count == 2 }
        let missed = try await sessions.lines(sid, generation: 0).filter { $0.position > left }.map(\.key)
        let heardSecond = await hear(&live) { Self.keys($0).count >= missed.count }.map(Self.keys)
        #expect(heardSecond == missed)

        var resumed = service.lines(sid, after: TranscriptCursor(generation: 0, position: left), as: Self.reader).makeAsyncIterator()
        frame = await resumed.next().map(Heard.init)
        #expect(frame == .lines(0, ["system"] + missed))

        let all = try await sessions.lines(sid, generation: 0).map(\.key)
        var stale = service.lines(sid, after: TranscriptCursor(generation: 3, position: 1), as: Self.reader).makeAsyncIterator()
        frame = await stale.next().map(Heard.init)
        #expect(frame == .reset(0, all))
      }
    }
  }

  @Test func `a new generation resets the tail`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let execution = SessionExecution(space: space, loopConfig: makeConfig())
      let sid = try await created(space)
      try await runService(execution) { service in
        var tail = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        var frame = await tail.next().map(Heard.init)
        #expect(frame == .reset(0, []))
        _ = try await service.restart(sid, executor: nil, note: "Started over.")
        frame = await tail.next().map(Heard.init)
        let opened = try await space.sessions.lines(sid, generation: 1).map(\.key)
        #expect(opened.first == "head")
        #expect(frame == .reset(1, opened))
      }
    }
  }

  private static func keys(_ heard: [Heard]) -> [String] {
    heard.flatMap { frame -> [String] in
      switch frame {
      case let .reset(_, keys), let .lines(_, keys): keys
      }
    }
  }

  /// Hears frames until `done` says what was heard so far is enough; nil if the tail ended first.
  private func hear(_ tail: inout AsyncStream<TranscriptTail.Outgoing>.Iterator, until done: ([Heard]) -> Bool) async -> [Heard]? {
    var heard: [Heard] = []
    while !done(heard) {
      guard let frame = await tail.next() else { return nil }
      heard.append(Heard(frame))
    }
    return heard
  }

  @Test func `a compaction resets the tail to the new generation`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let compact = ToolCall(id: "call_c", name: "compact", arguments: .object(["summary": .string("kept the notes")]))
      let script = InferenceScript([Fix.replying("folding", calls: [compact]), Fix.replying("fresh start")])
      let execution = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let sid = try await created(space)
      try await runService(execution) { service in
        var tail = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        #expect(await tail.next().map(Heard.init) == .reset(0, []))
        try await service.enqueue(item: Fix.message("go"), to: sid)
        let heard = await hear(&tail) { $0.contains { if case .reset(1, _) = $0 { true } else { false } } }
        try await until("fresh start") { try await sessions.settledWork(sid) && script.count == 2 }
        guard case let .reset(1, opened)? = heard?.last else {
          Issue.record("heard \(String(describing: heard))")
          return
        }
        let stored = try await sessions.lines(sid, generation: 1).map(\.key)
        #expect(opened.first == "head")
        #expect(Array(stored.prefix(opened.count)) == opened)
      }
    }
  }

  @Test func `lines written around a resume and an unarchive reach the tail`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([Fix.replying("first"), Fix.replying("second")])
      let execution = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let sid = try await created(space)
      try await runService(execution) { service in
        var tail = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        #expect(await tail.next().map(Heard.init) == .reset(0, []))

        try await service.interrupt(sid)
        try await until("interrupted") { try await sessions.record(sid).hold == .interrupted }
        try await service.enqueue(item: Fix.message("one", message: "m1"), to: sid)
        try await service.resume(sid)
        var heard = await hear(&tail) { Self.keys($0).contains("message:m1") }
        #expect(heard.map(Self.keys) == ["message:m1"])

        try await until("first reply") { try await sessions.settledWork(sid) && script.count == 1 }
        try await service.archive(sid)
        try await until("archived") { if case .archived = try await sessions.record(sid).lifecycle { true } else { false } }
        try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await service.unarchive(sid)
        heard = await hear(&tail) { Self.keys($0).contains("message:m2") }
        #expect(heard.map(Self.keys)?.last == "message:m2")
      }
    }
  }

  @Test func `a viewer who does not read the session's group is closed, at attach or at the next line`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let owner = try await space.addAccount(kind: .human, name: "alice")
      let group = try await space.createGroup(alias: "plans", owner: owner.id)
      let script = InferenceScript([Fix.replying("first")])
      let execution = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let sid = try await created(space, in: group)
      try await runService(execution) { service in
        var tail = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        let frame = await tail.next().map(Heard.init)
        #expect(frame == .reset(0, []))
        try await space.setVisibility(.private, of: group, by: .person(persona: "alice", account: owner.id), acting: group)
        var refused = service.lines(sid, after: nil, as: Self.reader).makeAsyncIterator()
        #expect(await refused.next() == nil)

        try await service.enqueue(item: Fix.message("one"), to: sid)
        #expect(await tail.next() == nil)
      }
    }
  }
}
