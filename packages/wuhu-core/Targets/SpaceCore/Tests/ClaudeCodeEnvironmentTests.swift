import Foundation
import JSONValue
import OrderedCollections
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct ClaudeCodeEnvironmentTests {
  typealias Entry = OrderedDictionary<String, JSONValue>

  private static func claudeSession(_ store: SessionStore, kind: SessionKind = .agent) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "claude", kind: kind, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      snapshot: .init(),
    )
  }

  private static func toolResult(_ uuid: String, _ toolCallID: String) -> Entry {
    [
      "type": "user",
      "uuid": .string(uuid),
      "timestamp": "2026-09-23T06:18:00.514Z",
      "message": ["role": "user", "content": [["tool_use_id": .string(toolCallID), "type": "tool_result", "content": "ok"]]],
    ]
  }

  private static func additionalContext(_ uuid: String, event: String, toolCallID: String) -> Entry {
    [
      "type": "attachment",
      "uuid": .string(uuid),
      "attachment": ["type": "hook_additional_context", "content": ["x"], "toolUseID": .string(toolCallID), "hookEvent": .string(event)],
    ]
  }

  private static func post(_ conversation: String) -> ToolResultPayload {
    .sendMessage(.init(messageID: .init("p-\(conversation)"), conversationID: .init(conversation), n: 1))
  }

  // The live smoke's case: the prompt's entry and a boundary that does not
  // carry it arrive in one mirror frame. The confirmation lands at the entry,
  // so the boundary's snapshot already holds the delivery.
  @Test func aDeliveryConfirmedInTheFrameOfTheBoundaryAfterItReachesTheNextGeneration() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      _ = try await store.enqueue(id, input: SessionFix.message(message: "m1", conversation: "box", owesReply: true))
      let handover = ClaudeCodeHandover(
        record: .userEntry(uuid: "u1"), through: 1, note: false, nag: nil, compactionNotice: false, at: fixedDate,
      )

      let entry = try await store.appendClaudeCodeMirror(id, entries: [["type": "assistant", "uuid": "x0"]], confirming: handover)
      #expect(entry == nil, "a frame without the record confirms nothing")
      #expect(try await store.undrainedInputs(id).map(\.id) == [1])

      let confirmed = try await store.appendClaudeCodeMirror(id, entries: [
        ["type": "user", "uuid": "u1", "message": ["role": "user", "content": "one"]],
        ["type": "system", "subtype": "compact_boundary", "uuid": "b1", "compactMetadata": ["trigger": "auto"]],
        ["type": "user", "uuid": "s1", "isCompactSummary": true],
      ], confirming: handover)
      #expect(confirmed == "u1")
      #expect(try await store.undrainedInputs(id).isEmpty)
      #expect(try await store.claudeCodeLog(id).entries.map { $0["uuid"] } == ["b1", "s1"], "the boundary carried nothing")
      #expect(try await store.claudeCodeEnvironment(id).nag(task: false, now: fixedDate) == .owedReply(conversations: [.init("box")]))
    }
  }

  // Stdin, the after-each-tool hook and the end-of-turn hook, each joined by
  // the entry that confirmed it; posts joined by their tool call ids.
  @Test func theFoldJoinsEveryDeliveryPathAndEveryReceiptInLogOrder() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      for (index, conversation) in ["box", "dm2", "dm3"].enumerated() {
        _ = try await store.enqueue(id, input: SessionFix.message(message: "m\(index)", conversation: conversation, owesReply: true))
      }
      try await store.recordReceipt(id, toolCallID: ToolCallID("t1"), payload: Self.post("box"))
      try await store.recordReceipt(id, toolCallID: ToolCallID("t2"), payload: Self.post("dm2"))

      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "u1", "message": ["role": "user", "content": "one"]]])
      try await store.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "u1", handedOverAt: fixedDate)
      try await store.appendClaudeCodeMirror(id, entries: [
        ["type": "assistant", "uuid": "x1"],
        Self.toolResult("r1", "t1"),
        Self.additionalContext("a1", event: "PostToolUse", toolCallID: "t1"),
      ])
      try await store.confirmClaudeCodeHandover(id, through: 2, note: false, entry: "a1", handedOverAt: fixedDate)
      try await store.appendClaudeCodeMirror(id, entries: [Self.additionalContext("a2", event: "Stop", toolCallID: "hook-run")])
      try await store.confirmClaudeCodeHandover(
        id, through: 3, note: false, nag: .owedReply(conversations: [.init("dm2")]), entry: "a2", handedOverAt: fixedDate,
      )

      let environment = try await store.claudeCodeEnvironment(id)
      #expect(
        environment.nag(task: false, now: fixedDate) == .owedReply(conversations: [.init("dm3")]),
        "the box was answered after its delivery; dm2's delivery came after the post and was then nagged",
      )
      #expect(try await store.undrainedInputs(id).isEmpty)

      // t2 ran, but the log does not show it yet: only the running turn's receipts count.
      let pending = try await store.claudeCodeEnvironment(id, pendingSince: fixedDate)
      #expect(pending != environment, "t2 answered dm2")
      #expect(pending.nag(task: false, now: fixedDate) == .owedReply(conversations: [.init("dm3")]))
      #expect(try await store.claudeCodeEnvironment(id, pendingSince: fixedDate.addingTimeInterval(1)) == environment)
    }
  }

  @Test func aCompactionBoundaryCarriesTheEnvironmentIntoTheGenerationItOpens() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      _ = try await store.enqueue(id, input: SessionFix.message(message: "m0", conversation: "dm2", owesReply: true))
      _ = try await store.enqueue(id, input: SessionFix.message(message: "m1", conversation: "dm3", owesReply: true))
      try await store.recordReceipt(id, toolCallID: ToolCallID("t2"), payload: Self.post("dm2"))
      try await store.recordReceipt(
        id, toolCallID: ToolCallID("t3"),
        payload: .timer(.init(subscriptionID: .init("timer.t"), schedule: .cron("0 * * * *"), message: "tick")),
      )
      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "u1", "message": ["role": "user", "content": "one"]]])
      try await store.confirmClaudeCodeHandover(id, through: 2, note: false, entry: "u1", handedOverAt: fixedDate)
      try await store.appendClaudeCodeMirror(id, entries: [Self.toolResult("r3", "t3")])
      let before = try await store.claudeCodeEnvironment(id)
      #expect(before != SessionEnvironment())

      try await store.appendClaudeCodeMirror(id, entries: [[
        "type": "system", "subtype": "compact_boundary", "uuid": "b",
        "compactMetadata": ["trigger": "auto", "preservedMessages": ["allUuids": []]],
      ]])
      #expect(try await store.generationState(id).generation == 1)
      #expect(try await store.claudeCodeEnvironment(id) == before, "the summary lost it; the snapshot did not")

      try await store.appendClaudeCodeMirror(id, entries: [Self.toolResult("r2", "t2")])
      #expect(try await store.claudeCodeEnvironment(id).nag(task: false, now: fixedDate) == .owedReply(conversations: [.init("dm3")]))

      try await store.settleClaudeCodeTurn(id)
      try await store.restart(id, note: nil)
      #expect(try await store.claudeCodeEnvironment(id) == SessionEnvironment(), "restart starts from nothing")
    }
  }

  @Test func aClaudeCodeSessionIsNeverNaggedByAQueuedRow() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let agent = try await Self.claudeSession(store)
      _ = try await store.enqueue(agent, input: SessionFix.message(conversation: agent.rawValue, owesReply: true))
      try await store.confirmClaudeCodeHandover(agent, through: 1, note: false, entry: "u1", handedOverAt: fixedDate)
      try await store.settleClaudeCodeTurn(agent)
      #expect(try await store.undrainedInputs(agent).isEmpty)
      #expect(try await store.record(agent).work == .noWork)

      let task = try await Self.claudeSession(store, kind: .task)
      let idle = try await Self.claudeSession(store, kind: .task)
      let row = try await store.enqueue(task, input: .message(.init(
        id: UUID(), messageID: .init("r1"), conversationID: .init("dm"), sender: SessionFix.sender, timestamp: fixedDate,
        kind: .request, requestID: .init("r1"), content: .init(text: "do it"),
      )))
      try await store.confirmClaudeCodeHandover(task, through: row, note: false, entry: "u2", handedOverAt: fixedDate)
      try await store.settleClaudeCodeTurn(task)
      let booted = try await store.bootSessions()
      #expect(booted.contains(task), "a task's park wake is scheduled by loading it")
      #expect(!booted.contains(idle), "a task with no open request has no park wake")
      #expect(!booted.contains(agent))
    }
  }
}
