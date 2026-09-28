import ClaudeStream
import Foundation
import JSONValue
import OrderedCollections
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite struct ClaudeCodeTranscriptTests {
  typealias Entry = OrderedDictionary<String, JSONValue>

  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/claude-code")

  private static func mirrorFrames(_ run: String) throws -> [[Entry]] {
    var reader = ClaudeStreamReader()
    return reader.read(Array(try Data(contentsOf: fixtures.appendingPathComponent("\(run)-stdout.jsonl")))).compactMap { frame in
      if case let .transcriptMirror(entries) = frame { entries } else { nil }
    }
  }

  private static func claudeSession(_ store: SessionStore) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "claude", kind: .agent, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      snapshot: .init(),
    )
  }

  private static let timestamp = "2026-09-23T06:18:00.514Z"

  private static func notice(_ text: String, source: String) -> String {
    MessageHeader.systemNotice(source: SubscriptionID(source), at: fixedDate).render() + "\n\n" + text
  }

  private static func text(_ text: String) -> JSONValue {
    ["type": "text", "text": .string(text)]
  }

  private static func userEntry(_ uuid: String, _ content: [JSONValue]) -> Entry {
    ["type": "user", "uuid": .string(uuid), "timestamp": .string(timestamp), "message": ["role": "user", "content": .array(content)]]
  }

  private static func digest(_ item: TranscriptItem) -> String {
    switch item {
    case let .message(message):
      "message \(message.content.text)"
    case let .notification(notification):
      "notification \(notification.kind.rawValue)"
    case let .generationHead(head):
      "head \(head.summary.prefix(47)) | note \(head.note ?? "-")"
    case let .assistant(entry):
      "assistant " + entry.content.map { block in
        switch block {
        case let .text(text): "text \(text.text)"
        case let .reasoning(.unencrypted(thinking)): "thinking \(thinking)"
        case let .toolCall(call): "call \(call.id) \(call.name)"
        default: "other"
        }
      }.joined(separator: ", ")
    case let .toolResult(result):
      switch (result.provenance, result.payload) {
      case let (.toolCall(id), .claudeCode(logged)): "result \(id.rawValue) logged\(logged.isError ? " error" : ""): \(logged.text.prefix(30))"
      case let (.toolCall(id), .failure(failure)): "result \(id.rawValue) failure: \(failure.message.prefix(30))"
      case let (.toolCall(id), payload): "result \(id.rawValue) receipt \(payload.digestKind)"
      default: "other"
      }
    default:
      "other"
    }
  }

  // Claude Code's own log of a `/compact` run: a Wuhu call answered by its
  // receipt, a Wuhu call with none, and a built-in Read; then the head of the
  // generation the boundary opened, ahead of the line it carried.
  @Test func theManualFixtureReadsAsTheKernelTranscript() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      _ = try await store.enqueue(id, input: SessionFix.message("IMG-TURN", message: "m1"))
      let caption = ToolResultPayload.read(ReadResult(path: "/pic.png", revision: .journal(3), content: "MCP-IMAGE-CAPTION"))
      try await store.recordReceipt(id, toolCallID: ToolCallID("toolu_s001"), payload: caption)
      let handovers = [
        ClaudeCodeHandover(record: .userEntry(uuid: "05577e1e-b451-4e3c-bdb9-4ff7741936b7"), through: 1, note: false, nag: nil, compactionNotice: false, at: fixedDate),
        ClaudeCodeHandover(record: .userEntry(uuid: "75f87139-425e-4fee-b159-0bb72e518a80"), through: 2, note: false, nag: nil, compactionNotice: true, at: fixedDate),
      ]
      var generationZero: [TranscriptItem] = []
      for frame in try Self.mirrorFrames("manual") {
        if frame.contains(where: { $0["subtype"] == "compact_boundary" }) {
          generationZero = try await store.transcriptSnapshot(id).items
          _ = try await store.enqueue(id, input: SessionFix.message("AFTER-COMPACT hello", message: "m2"))
        }
        let confirming = handovers.first { handover in frame.contains(where: handover.record.isRecorded) }
        try await store.appendClaudeCodeMirror(id, entries: frame, confirming: confirming)
      }

      #expect(generationZero.map(Self.digest) == [
        "message IMG-TURN",
        "assistant call toolu_s001 img",
        "result toolu_s001 receipt read",
        "assistant call toolu_s002 ClaudeRead",
        "result toolu_s002 logged: ",
        "assistant call toolu_s003 big",
        "result toolu_s003 failure: Error: result (199,978 charact",
        "assistant text IMG-TURN-DONE",
      ])
      guard case let .toolResult(receipt) = generationZero[2] else { Issue.record("a tool result"); return }
      #expect(receipt.payload == caption)
      guard case let .assistant(read) = generationZero[3] else { Issue.record("an assistant entry"); return }
      #expect(read.toolCalls == [ToolCall(
        id: "toolu_s002", name: "ClaudeRead",
        arguments: ToolArguments(["file_path": "/Users/dev/wuhu-probe/runs/029-rebuild-123331/orig/work/pic.png"]),
      )])

      let (generation, items) = try await store.transcriptSnapshot(id)
      #expect(generation == 1)
      #expect(items.map(Self.digest).map { String($0.prefix(40)) } == [
        "head This session is being continued fro",
        "assistant text IMG-TURN-DONE",
        "message AFTER-COMPACT hello",
        "assistant text REPLY-TO: <system-reminde",
      ])
      #expect(items.first.map { if case let .generationHead(head) = $0 { head.id } else { nil } } == UUID(uuidString: "43d7e067-6120-4ade-8fcf-16a3fb64509d"))
    }
  }

  // An automatic compaction mid-turn: the boundary carries the pending call
  // and its result, which Claude Code wrote twice under one uuid.
  @Test func anAutomaticBoundaryOpensWithItsHeadThenTheCarriedLinesOnce() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      for frame in try Self.mirrorFrames("automatic") {
        try await store.appendClaudeCodeMirror(id, entries: frame)
      }
      let (generation, items) = try await store.transcriptSnapshot(id)
      #expect(generation == 1)
      let opening: [String] = items.prefix(4).map { String(Self.digest($0).prefix(60)) }
      #expect(opening == [
        "head This session is being continued from a previous | note ",
        "assistant call toolu_fake_2d47ee4ff7574b7d wuhu_big",
        "result toolu_fake_2d47ee4ff7574b7d failure: [19956 chars tri",
        "assistant call toolu_fake_6c6ed1ac124343ce wuhu_big",
      ])
    }
  }

  @Test func anAssistantLineIsOneEntryWithItsUsageAndStopReason() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      let at = try #require(claudeCodeTimestamp(Self.timestamp))
      try await store.appendClaudeCodeMirror(id, entries: [[
        "type": "assistant", "uuid": "8b9c8c1e-2f63-4a54-9d6d-3d1f6f0f6a01", "timestamp": .string(Self.timestamp),
        "message": [
          "role": "assistant", "stop_reason": "max_tokens",
          "usage": ["input_tokens": 10, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 3000, "output_tokens": 40],
          "content": [
            ["type": "thinking", "thinking": "", "signature": "s"],
            ["type": "thinking", "thinking": "plan", "signature": "s"],
            ["type": "text", "text": "reading"],
            ["type": "tool_use", "id": "toolu_1", "name": "mcp__wuhu__read", "input": ["path": "/notes.md"]],
            ["type": "tool_use", "id": "toolu_2", "name": "WebSearch", "input": ["query": "swift"]],
          ],
        ],
      ]])
      #expect(try await store.transcriptSnapshot(id).items == [.assistant(AssistantEntry(
        id: try #require(UUID(uuidString: "8b9c8c1e-2f63-4a54-9d6d-3d1f6f0f6a01")),
        timestamp: at,
        content: [
          .reasoning(.unencrypted("plan")),
          .text(TextContent(text: "reading")),
          .toolCall(ToolCall(id: "toolu_1", name: "read", arguments: ToolArguments(["path": "/notes.md"]))),
          .toolCall(ToolCall(id: "toolu_2", name: "WebSearch", arguments: ToolArguments(["query": "swift"]))),
        ],
        stopReason: .maxTokens,
        usage: Usage(inputTokens: 3210, outputTokens: 40, cacheReadTokens: 3000, cacheWriteTokens: 200, totalTokens: 3250),
        toolCallIDs: [:],
      ))])
    }
  }

  // Standard input carries the loop's own pieces ahead of the inputs; a hook
  // carries one joined string. Either way the transcript shows the recorded
  // effects: the nag as its notification, each input as delivered, and
  // neither the compaction line nor a continuation notice.
  @Test func aHandoverShowsWhatItCarried() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      let inputs = (1 ... 4).map { SessionFix.message("m\($0)", message: "m\($0)", conversation: "c\($0)", owesReply: true) }
      for input in inputs {
        _ = try await store.enqueue(id, input: input)
      }
      let nag = Nag.owedReply(conversations: [.init("c0")])

      try await store.appendClaudeCodeMirror(id, entries: [Self.userEntry("u1", [
        Self.text(Self.notice("compact nudge", source: "session.compaction")),
        Self.text(nag.rendered(at: fixedDate)),
        Self.text(Self.notice("continue", source: "session.continuation")),
        Self.text("m1"),
        Self.text("m2"),
      ])])
      try await store.confirmClaudeCodeHandover(id, through: 2, note: false, nag: nag, compactionNotice: true, entry: "u1", handedOverAt: fixedDate)

      let hook = [Self.notice("compact nudge", source: "session.compaction"), "m3", "m4"].joined(separator: "\n\n")
      try await store.appendClaudeCodeMirror(id, entries: [
        ["type": "attachment", "uuid": "a1", "attachment": [
          "type": "hook_additional_context", "hookEvent": "PostToolUse", "toolUseID": "toolu_1", "content": [.string(hook)],
        ]],
        Self.userEntry("u2", [Self.text(Self.notice("continue", source: "session.continuation"))]),
      ])
      try await store.confirmClaudeCodeHandover(id, through: 4, note: false, entry: "a1", handedOverAt: fixedDate)

      let items = try await store.transcriptSnapshot(id).items
      #expect(items == [.notification(nag.notification(id: UUID.deterministic("u1", "nag"), at: fixedDate))] + inputs.map(\.transcriptItem))
    }
  }

  @Test func theRestartNoteOpensTheGenerationAsItsHead() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      try await store.restart(id, note: "Started over on claude/opus.")
      let input = SessionFix.message("after", message: "m1")
      _ = try await store.enqueue(id, input: input)
      let at = try #require(claudeCodeTimestamp(Self.timestamp))

      try await store.appendClaudeCodeMirror(id, entries: [Self.userEntry("u1", [
        Self.text(Self.notice("Started over on claude/opus.", source: "session.restart")),
        Self.text("after"),
      ])])
      try await store.confirmClaudeCodeHandover(id, through: 1, note: true, entry: "u1", handedOverAt: fixedDate)

      let (generation, items) = try await store.transcriptSnapshot(id)
      #expect(generation == 1)
      #expect(items == [
        .generationHead(GenerationHead(
          id: UUID.deterministic("u1", "note"), timestamp: at, summary: "", snapshot: StateSnapshot(), note: "Started over on claude/opus.",
        )),
        input.transcriptItem,
      ])
    }
  }

  // The stream's positions are the snapshot's: a reconnect in the same
  // generation resumes past the client's cursor, and one from an older
  // generation resets.
  @Test func theStreamResumesAtTheClientsPosition() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      let frames = try Self.mirrorFrames("manual")
      let boundary = try #require(frames.firstIndex { $0.contains(where: { $0["subtype"] == "compact_boundary" }) })
      for frame in frames[..<boundary] {
        try await store.appendClaudeCodeMirror(id, entries: frame)
      }
      let snapshot = try await store.transcriptSnapshot(id).items
      #expect(snapshot.count == 7)

      var fresh = store.observeTranscript(id).makeAsyncIterator()
      let first = try #require(try await fresh.next())
      #expect(first == TranscriptPage(generation: 0, startPosition: 0, items: snapshot, reset: true))

      var resumed = store.observeTranscript(id, from: TranscriptCursor(generation: 0, position: 3)).makeAsyncIterator()
      let resumedPage = try #require(try await resumed.next())
      #expect(resumedPage == TranscriptPage(generation: 0, startPosition: 4, items: Array(snapshot[4...]), reset: false))

      try await store.appendClaudeCodeMirror(id, entries: frames[boundary])
      let next = try #require(try await resumed.next())
      let current = try await store.transcriptSnapshot(id)
      #expect(next == TranscriptPage(generation: 1, startPosition: 0, items: current.items, reset: true))

      var stale = store.observeTranscript(id, from: TranscriptCursor(generation: 0, position: 6)).makeAsyncIterator()
      #expect(try await stale.next() == TranscriptPage(generation: 1, startPosition: 0, items: current.items, reset: true))
    }
  }
}

private extension ToolResultPayload {
  var digestKind: String {
    if case .read = self { "read" } else { "other" }
  }
}
