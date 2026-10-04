import ClaudeStream
import Foundation
import GRDB
import JSONValue
import OrderedCollections
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct ClaudeCodeHistoryTests {
  typealias Entry = OrderedDictionary<String, JSONValue>

  private static func session(_ store: SessionStore) async throws -> SessionID {
    try await store.createSession(
      group: .shared, title: "claude", kind: .agent, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")), snapshot: .init(),
    )
  }

  private static func assistant(_ index: Int, calls: [JSONValue] = []) -> Entry {
    ["type": "assistant", "uuid": .string("a\(index)"), "message": ["content": .array([
      ["type": "text", "text": .string("text \(index)")],
    ] + calls)]]
  }

  private static func call(_ id: String, name: String = "mcp__wuhu__read") -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]
  }

  private static func results(_ count: Int) -> Entry {
    ["type": "user", "uuid": "results", "message": ["content": .array((0 ..< count).map {
      ["type": "tool_result", "tool_use_id": .string("call\($0)"), "content": .string("result \($0)")]
    })]]
  }

  private static func prepare(_ store: SessionStore, _ id: SessionID, generation: Int = 0) async throws {
    for _ in 0 ..< 100 {
      if try await store.prepareClaudeCodeHistory(id, generation: generation) { return }
    }
    Issue.record("Claude projection failed to become ready within 100 bounded chunks")
  }

  private static func page(_ space: Space, _ id: SessionID, generation: Int64 = 0, limit: Int = 200, before: Int? = nil, epoch: String? = nil) async throws -> TranscriptHistoryPage {
    try await space.writer.read { db in
      try Sessions.claudeCodeHistory(id.rawValue, generation: generation, limit: limit, before: before, expectedEpoch: epoch ?? Sessions.claudeCodeHistoryEpoch(id.rawValue, in: db), in: db)
    }
  }

  private static func after(_ space: Space, _ id: SessionID, generation: Int64 = 0, position: Int, epoch: String? = nil) async throws -> TranscriptPage {
    try await space.writer.read { db in
      try Sessions.claudeCodeHistoryAfter(id.rawValue, generation: generation, after: position, epoch: epoch ?? Sessions.claudeCodeHistoryEpoch(id.rawValue, in: db), in: db)
    }
  }

  @Test(arguments: ["manual", "automatic"]) func recordedFixtureParity(run: String) async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      _ = try await space.sessions.enqueue(id, input: SessionFix.message("IMG-TURN", message: "m1"))
      try await space.sessions.recordReceipt(id, toolCallID: ToolCallID("toolu_s001"), payload: .read(.init(path: "/pic.png", revision: .journal(3), content: "caption")))
      let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-code/\(run)-stdout.jsonl")
      var reader = ClaudeStreamReader()
      for frame in reader.read(Array(try Data(contentsOf: path))) {
        guard case let .transcriptMirror(entries) = frame else { continue }
        try await space.sessions.appendClaudeCodeMirror(id, entries: entries)
        let snapshot = try await space.sessions.transcriptSnapshot(id)
        try await Self.prepare(space.sessions, id, generation: snapshot.generation)
        let page = try await Self.page(space, id, generation: Int64(snapshot.generation))
        #expect(page.entries.map(\.item) == snapshot.items)
        #expect(page.entries.map(\.position) == Array(snapshot.items.indices))
        #expect(page.headPosition == snapshot.items.indices.last)
      }
    }
  }

  @Test func oneRawResultLineResumesWithinTheLineAndLoadsDistinctOrigins() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [
        Self.assistant(0, calls: (0 ..< 451).map { Self.call("call\($0)", name: $0 == 450 ? "Read" : "mcp__wuhu__read") }),
        Self.results(451), Self.results(451),
      ])
      for _ in 0 ..< 3 {
        let work = try await space.writer.write { db in
          try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: 0, in: db, maximumSourceReads: 1, maximumSteps: 50)
        }
        #expect(work.sourceReads <= 1)
        #expect(work.steps <= 50)
        #expect(work.emitted <= 50)
        #expect(!work.ready)
        await #expect(throws: TranscriptHistoryError.preparing(generation: 0)) { try await Self.page(space, id) }
      }
      try await Self.prepare(space.sessions, id)
      let snapshot = try await space.sessions.transcriptSnapshot(id)
      let tail = try await Self.page(space, id, limit: 50)
      #expect(snapshot.items.count == 452)
      #expect(tail.entries.map(\.item) == Array(snapshot.items.suffix(50)))
      #expect(tail.entries.map(\.position) == Array(402 ... 451))
      #expect(tail.origins.map(\.position) == [0])
      #expect(tail.origins.map(\.item) == [snapshot.items[0]])
      #expect(tail.before == 402)
      #expect(tail.hasEarlier)
      guard case let .toolResult(builtin) = tail.entries.last?.item else { Issue.record("builtin result"); return }
      #expect(builtin.payload == .claudeCode(.init(text: "result 450", isError: false)))
      guard case let .toolResult(wuhu) = tail.entries.first?.item else { Issue.record("Wuhu result"); return }
      #expect(wuhu.payload == .failure(.init(message: "result 401")))
      let earlier = try await Self.page(space, id, limit: 50, before: tail.before)
      #expect(earlier.entries.map(\.position) == Array(352 ... 401))
      #expect(earlier.headPosition == tail.headPosition)
      let all = try await Self.page(space, id, limit: 500)
      #expect(all.entries.map(\.item) == snapshot.items)
      #expect(all.origins.isEmpty)
      #expect(!all.hasEarlier)
    }
  }

  @Test func readyReadsAvoidRawPayloadsAndForwardResumesExactlyOnce() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      try await space.sessions.appendClaudeCodeMirror(id, entries: (0 ..< 1000).map { Self.assistant($0) })
      var chunks = 0
      while true {
        let work = try await space.writer.write { db in
          try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: 0, in: db)
        }
        chunks += 1
        #expect(work.sourceReads <= 100)
        #expect(work.steps <= 200)
        #expect(work.emitted <= 200)
        if work.ready { break }
        #expect(chunks <= 10)
      }
      #expect(chunks == 10)
      let snapshot = try await space.sessions.transcriptSnapshot(id)
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE session_contents SET payload = '{\"unexpected\":true}' WHERE session_id = ?", arguments: [id.rawValue])
      }
      let tail = try await Self.page(space, id, limit: 25)
      #expect(tail.entries.map(\.item) == Array(snapshot.items.suffix(25)))
      #expect(tail.headPosition == 999)
      let idleWork = try await space.writer.write { db in
        try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: 0, in: db)
      }
      #expect(idleWork.sourceReads == 0)
      #expect(idleWork.ready)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [Self.assistant(1000), Self.assistant(1001)])
      let forward = try await Self.after(space, id, position: 999)
      #expect(!forward.reset)
      #expect(forward.startPosition == 1000)
      #expect(try await Self.page(space, id, limit: 2).historyEpoch == tail.historyEpoch)
      #expect(forward.items == (try await Self.page(space, id, limit: 2)).entries.map(\.item))
      let caughtUp = try await Self.after(space, id, position: 1001)
      #expect(!caughtUp.reset)
      #expect(caughtUp.items.isEmpty)
      #expect((try await Self.after(space, id, position: 800)).reset)
      #expect((try await Self.after(space, id, position: 1002)).reset)
      #expect((try await Self.after(space, id, position: -2)).reset)
    }
  }

  @Test func cancellationRollsBackAndVersionMismatchRebuildsOnlyDerivedState() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      try await space.sessions.appendClaudeCodeMirror(id, entries: (0 ..< 10).map { Self.assistant($0) })
      await #expect(throws: CancellationError.self) {
        try await space.writer.write { db in
          var checks = 0
          _ = try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: 0, in: db, checkCancellation: {
            checks += 1
            if checks == 5 { throw CancellationError() }
          })
        }
      }
      #expect(try await space.writer.read { try Sessions.claudeHistoryProgress(id.rawValue, generation: 0, in: $0) } == nil)
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await space.sessions.prepareClaudeCodeHistory(id, generation: 0)
      }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      try await Self.prepare(space.sessions, id)
      let expected = try await Self.page(space, id).entries
      try await space.writer.write { db in
        try db.execute(sql: "UPDATE claude_history_progress SET version = 0 WHERE session_id = ?", arguments: [id.rawValue])
      }
      await #expect(throws: TranscriptHistoryError.preparing(generation: 0)) { try await Self.page(space, id) }
      #expect((try await Self.after(space, id, position: 0)).reset)
      try await Self.prepare(space.sessions, id)
      #expect(try await Self.page(space, id).entries == expected)
      try await space.writer.write { db in try Sessions.discardClaudeHistory(id.rawValue, generation: 0, in: db) }
      #expect(try await space.sessions.transcriptSnapshot(id).items == expected.map(\.item))
      try await Self.prepare(space.sessions, id)
      #expect(try await Self.page(space, id).entries == expected)
      try await space.sessions.restart(id, note: "restart")
      await #expect(throws: TranscriptHistoryError.generationChanged(expected: 0, actual: 1)) {
        try await space.sessions.prepareClaudeCodeHistory(id, generation: 0)
      }
    }
  }

  @Test func lateSummaryReopensAnEmptyPreparedCompactionAndHandoverInvalidates() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [Self.assistant(0)])
      try await Self.prepare(space.sessions, id)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [[
        "type": "system", "subtype": "compact_boundary", "uuid": "boundary", "compactMetadata": [
          "trigger": "auto", "preservedMessages": ["allUuids": ["a0"]],
        ],
      ]])
      try await Self.prepare(space.sessions, id, generation: 1)
      let waiting = try await Self.page(space, id, generation: 1)
      #expect(waiting.entries.isEmpty)
      #expect(waiting.headPosition == nil)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [[
        "type": "user", "uuid": "summary", "isCompactSummary": true, "message": ["content": "compact summary"],
      ]])
      let opened = try await Self.page(space, id, generation: 1)
      #expect(opened.entries.map(\.item) == (try await space.sessions.transcriptSnapshot(id)).items)
      #expect(opened.entries.count == 2)
      guard case .generationHead = opened.entries.first?.item else { Issue.record("summary first"); return }
      let forward = try await Self.after(space, id, generation: 1, position: -1)
      #expect(!forward.reset)
      #expect(forward.items == opened.entries.map(\.item))
      let input = SessionFix.message("delivered")
      _ = try await space.sessions.enqueue(id, input: input)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [[
        "type": "attachment", "uuid": "handover", "attachment": ["type": "hook_additional_context", "content": ["delivered"]],
      ]])
      #expect(try await Self.page(space, id, generation: 1).entries.count == 2)
      try await space.sessions.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "handover", handedOverAt: fixedDate)
      await #expect(throws: TranscriptHistoryError.preparing(generation: 1)) { try await Self.page(space, id, generation: 1) }
      try await Self.prepare(space.sessions, id, generation: 1)
      let rebuilt = try await Self.page(space, id, generation: 1)
      #expect(rebuilt.entries.map(\.item) == opened.entries.map(\.item) + [input.transcriptItem])
      #expect(rebuilt.historyEpoch != opened.historyEpoch)
      #expect((try await Self.after(space, id, generation: 1, position: 1, epoch: opened.historyEpoch)).reset)
      await #expect(throws: TranscriptHistoryError.historyChanged) {
        try await Self.page(space, id, generation: 1, before: 2, epoch: opened.historyEpoch)
      }
      let missingEpoch = try await space.writer.read { db in
        try Sessions.claudeCodeHistoryAfter(id.rawValue, generation: 1, after: 1, in: db)
      }
      #expect(missingEpoch.reset)
    }
  }

  @Test func preparationRacingAppendHandoverAndReceiptPublishesOneConsistentHead() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      let input = SessionFix.message("racing delivery")
      _ = try await space.sessions.enqueue(id, input: input)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [
        ["type": "user", "uuid": "handover", "message": ["content": "racing delivery"]],
      ] + (0 ..< 500).map { Self.assistant($0) })
      #expect(try await space.sessions.prepareClaudeCodeHistory(id, generation: 0) == false)
      let receipt = ToolResultPayload.grep(.init(output: "racing receipt"))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { _ = try await space.sessions.prepareClaudeCodeHistory(id, generation: 0) }
        group.addTask {
          try await space.sessions.appendClaudeCodeMirror(id, entries: [Self.assistant(500, calls: [Self.call("call0")]), Self.results(1)])
        }
        group.addTask {
          try await space.sessions.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "handover", handedOverAt: fixedDate)
        }
        group.addTask {
          try await space.sessions.recordReceipt(id, toolCallID: ToolCallID("call0"), payload: receipt)
        }
        try await group.waitForAll()
      }
      try await Self.prepare(space.sessions, id)
      let snapshot = try await space.sessions.transcriptSnapshot(id)
      let page = try await Self.page(space, id, limit: 600)
      #expect(page.entries.map(\.item) == snapshot.items)
      #expect(page.entries.map(\.position) == Array(snapshot.items.indices))
      #expect(page.entries.first?.item == input.transcriptItem)
      #expect(page.headPosition == snapshot.items.count - 1)
      guard case let .toolResult(result) = page.entries.last?.item else { Issue.record("result"); return }
      #expect(result.payload == receipt)
    }
  }

  @Test func reopeningOldSpacesAddsOnlyDisposableTablesAndRebuildsAfterDiscard() async throws {
    let folder = try scratchURL("claude-history")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await Self.session(space.sessions)
      try await space.sessions.appendClaudeCodeMirror(id, entries: (0 ..< 150).map { Self.assistant($0) })
      let snapshot = try await space.sessions.transcriptSnapshot(id)
      #expect(try await space.writer.read { try Sessions.claudeHistoryProgress(id.rawValue, generation: 0, in: $0) } == nil)
      try await space.writer.write { db in
        for table in ["claude_history_progress", "claude_history_items", "claude_history_seen", "claude_history_calls"] {
          try db.execute(sql: "DROP TABLE \"\(table)\"")
        }
      }
      let upgraded = try Space.open(file: file)
      #expect(try await upgraded.sessions.transcriptSnapshot(id).items == snapshot.items)
      #expect(try await upgraded.writer.read { try Sessions.claudeHistoryProgress(id.rawValue, generation: 0, in: $0) } == nil)
      #expect(try await upgraded.sessions.prepareClaudeCodeHistory(id, generation: 0) == false)
      let partial = try Space.open(file: file)
      try await Self.prepare(partial.sessions, id)
      let ready = try Space.open(file: file)
      #expect(try await Self.page(ready, id).entries.map(\.item) == snapshot.items)
      try await ready.writer.write { db in try Sessions.discardClaudeHistory(id.rawValue, generation: 0, in: db) }
      #expect(try await ready.sessions.transcriptSnapshot(id).items == snapshot.items)
      try await Self.prepare(ready.sessions, id)
      #expect(try await Self.page(ready, id).entries.map(\.item) == snapshot.items)
    }
  }

  @Test func anOldOperationReplayIsDetectedOnFreshOpenBeforeServingStaleOrdinals() async throws {
    let folder = try scratchURL("claude-history-old-operation")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await Self.session(space.sessions)
      let input = SessionFix.message("late old operation")
      let queueID = try await space.sessions.enqueue(id, input: input)
      try await space.sessions.appendClaudeCodeMirror(id, entries: [Self.assistant(0), [
        "type": "user", "uuid": "old-handover", "message": ["content": "delivered"],
      ], Self.assistant(1)])
      try await Self.prepare(space.sessions, id)
      let original = try await Self.page(space, id)
      let rawBefore = try await space.sessions.hydrate(id).transcript
      let rawHeadBefore = try await space.writer.read { try Sessions.claudeHistoryRawHead(id.rawValue, generation: 0, in: $0) }
      try await space.writer.write { db in
        let effect = try Sessions.encode(ClaudeCodeHandoverEffect.queue(queueID))
        try db.execute(
          sql: "INSERT INTO claude_code_handovers (session_id, entry_uuid, effect, handed_over_at) VALUES (?, ?, ?, ?)",
          arguments: [id.rawValue, "old-handover", effect, SQLiteDateFormat.string(from: fixedDate)],
        )
      }
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.hydrate(id).transcript == rawBefore)
      #expect(try await reopened.writer.read { try Sessions.claudeHistoryRawHead(id.rawValue, generation: 0, in: $0) } == rawHeadBefore)
      await #expect(throws: TranscriptHistoryError.preparing(generation: 0)) { try await Self.page(reopened, id) }
      #expect((try await Self.after(reopened, id, position: 1, epoch: original.historyEpoch)).reset)
      try await Self.prepare(reopened.sessions, id)
      let rebuilt = try await Self.page(reopened, id)
      #expect(rebuilt.historyEpoch != original.historyEpoch)
      #expect(rebuilt.entries.map(\.item) == [original.entries[0].item, input.transcriptItem, original.entries[1].item])
      #expect((try await Self.after(reopened, id, position: 1, epoch: original.historyEpoch)).reset)
      await #expect(throws: TranscriptHistoryError.historyChanged) {
        try await Self.page(reopened, id, before: 2, epoch: original.historyEpoch)
      }
      #expect(try await reopened.sessions.hydrate(id).transcript == rawBefore)
    }
  }

  @Test func receiptsRemainLiveOverlayAndHandoverExpansionIsBounded() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.session(space.sessions)
      let inputs = (0 ..< 225).map { SessionFix.message("m\($0)", message: "m\($0)") }
      for input in inputs { _ = try await space.sessions.enqueue(id, input: input) }
      try await space.sessions.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "handover", "message": ["content": "delivered"]]])
      try await space.sessions.confirmClaudeCodeHandover(id, through: 225, note: false, entry: "handover", handedOverAt: fixedDate)
      for _ in 0 ..< 2 {
        let work = try await space.writer.write { db in
          try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: 0, in: db, maximumSteps: 100)
        }
        #expect(work.emitted <= 100)
        #expect(work.steps <= 100)
        #expect(!work.ready)
      }
      try await Self.prepare(space.sessions, id)
      #expect(try await Self.page(space, id, limit: 300).entries.map(\.item) == inputs.map(\.transcriptItem))
      try await space.sessions.appendClaudeCodeMirror(id, entries: [Self.assistant(0, calls: [Self.call("call0")]), Self.results(1)])
      let first = ToolResultPayload.grep(.init(output: "first"))
      let second = ToolResultPayload.grep(.init(output: "second"))
      for receipt in [first, second] {
        try await space.sessions.recordReceipt(id, toolCallID: ToolCallID("call0"), payload: receipt)
        guard case let .toolResult(result) = try await Self.page(space, id, limit: 1).entries.first?.item else { Issue.record("result"); return }
        #expect(result.payload == first)
      }
    }
  }
}
