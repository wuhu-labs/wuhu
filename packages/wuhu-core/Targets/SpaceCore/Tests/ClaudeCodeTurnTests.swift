import Foundation
import JSONValue
import OrderedCollections
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct ClaudeCodeTurnTests {
  private static func claudeSession(_ store: SessionStore) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "claude", kind: .agent, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      snapshot: .init(),
    )
  }

  @Test func handedOverRowsDrainOnlyWhenConfirmedAndAsOfTheHandover() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      _ = try await store.enqueue(id, input: SessionFix.message("one", conversation: id.rawValue, owesReply: true))
      _ = try await store.enqueue(id, input: SessionFix.message("two", message: "m2"))
      #expect(try await store.undrainedInputs(id).map(\.id) == [1, 2])
      _ = try await store.post(
        .box(id), messageID: .init("a1"), sender: Sender(id: id.rawValue, timeZone: .gmt),
        senderSession: id, content: .init(text: "answered"),
      )

      try await store.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "u", handedOverAt: fixedDate.addingTimeInterval(-10))
      #expect(try await store.undrainedInputs(id).map(\.id) == [2])
      #expect(try await store.settleState(id).owedConversations.isEmpty, "shown before the answer, so answered")
      #expect(try await store.hydrate(id).queueTail == 1)
    }
  }

  @Test func aRowShownAfterTheAnswerIsStillOwed() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      _ = try await store.enqueue(id, input: SessionFix.message("one", conversation: id.rawValue, owesReply: true))
      _ = try await store.post(
        .box(id), messageID: .init("a1"), sender: Sender(id: id.rawValue, timeZone: .gmt),
        senderSession: id, content: .init(text: "answered"),
      )
      try await store.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "u", handedOverAt: fixedDate.addingTimeInterval(10))
      #expect(try await store.settleState(id).owedConversations == [ConversationID(id.rawValue)])
    }
  }

  @Test func aSettledTurnLeavesWorkOnlyForRowsStillQueued() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      try await store.beginClaudeCodeTurn(id)
      #expect(try await store.record(id).work == .hasWork, "a continuation is work without a queue row")
      #expect(try await store.bootSessions() == [id])
      try await store.settleClaudeCodeTurn(id)
      #expect(try await store.record(id).work == .noWork)

      _ = try await store.enqueue(id, input: SessionFix.message())
      try await store.settleClaudeCodeTurn(id)
      #expect(try await store.record(id).work == .hasWork)
      try await store.confirmClaudeCodeHandover(id, through: 1, note: false, entry: "u", handedOverAt: fixedDate)
      try await store.settleClaudeCodeTurn(id)
      #expect(try await store.record(id).work == .noWork)
    }
  }

  @Test func restartBetweenClaudeCodeSessionsStartsAFreshConversationWithItsNotePending() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "a"]])
      let before = try await store.claudeCodeLog(id)

      let restart = try await store.restart(id, note: "Started over.")
      #expect(restart.generation == 1)
      let after = try await store.claudeCodeLog(id)
      #expect(after.entries.isEmpty)
      #expect(after.sessionID != before.sessionID)
      #expect(try await store.claudeCodePendingNote(id) == "Started over.")
      #expect(try await store.record(id).work == .noWork, "and stays inert")

      try await store.confirmClaudeCodeHandover(id, through: nil, note: false, entry: "u", handedOverAt: fixedDate)
      #expect(try await store.claudeCodePendingNote(id) == "Started over.")
      try await store.confirmClaudeCodeHandover(id, through: nil, note: true, entry: "u", handedOverAt: fixedDate)
      #expect(try await store.claudeCodePendingNote(id) == nil)
    }
  }

  @Test func aCompactionOwesItsNoticeUntilAHandoverAfterItsBoundaryRecordsIt() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      func boundary(_ uuid: String, _ trigger: String, carrying: [JSONValue]) -> OrderedDictionary<String, JSONValue> {
        ["type": "system", "subtype": "compact_boundary", "uuid": .string(uuid), "compactMetadata": [
          "trigger": .string(trigger), "preservedMessages": ["allUuids": .array(carrying)],
        ]]
      }
      func owed() async throws -> CompactionTrigger? { try await store.claudeCodeOwedCompactionNotice(id) }

      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "a"]])
      #expect(try await owed() == nil, "nothing compacted yet")
      try await store.confirmClaudeCodeHandover(id, through: nil, note: false, compactionNotice: true, entry: "a", handedOverAt: fixedDate)

      try await store.appendClaudeCodeMirror(id, entries: [boundary("b1", "manual", carrying: ["a"]), ["type": "user", "uuid": "b"]])
      #expect(try await owed() == .manual, "a notice recorded against a carried entry was shown before the boundary")
      try await store.confirmClaudeCodeHandover(id, through: nil, note: false, entry: "b", handedOverAt: fixedDate)
      #expect(try await owed() == .manual, "a handover without the notice leaves it owed")
      try await store.confirmClaudeCodeHandover(id, through: nil, note: false, compactionNotice: true, entry: "b", handedOverAt: fixedDate)
      #expect(try await owed() == nil)
      #expect(try await store.claudeCodeEnvironment(id) == SessionEnvironment(), "the fold ignores a notice")

      try await store.appendClaudeCodeMirror(id, entries: [boundary("b2", "auto", carrying: ["b"])])
      #expect(try await owed() == .automatic, "every compaction owes its own")
      _ = try await store.restart(id, note: "Started over.")
      #expect(try await owed() == nil, "a restart is no compaction")
    }
  }

  @Test func restartSwitchesBetweenTheKernelAndClaudeCodeBothWays() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "k", kind: .agent, createdBy: "morgan", model: .test)
      let claude = SessionExecutor.claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high"))

      try await store.restart(id, executor: claude, note: "Now on Claude Code.")
      #expect(try await store.record(id).executor == claude)
      #expect(try await store.claudeCodeLog(id).entries.isEmpty)
      #expect(try await store.claudeCodePendingNote(id) == "Now on Claude Code.")
      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "a"]])

      try await store.restart(id, executor: .kernel(.test), note: "Back on the kernel.")
      guard case let .kernel(transcript) = try await store.hydrate(id).transcript,
            case let .generationHead(head) = transcript.items.first
      else {
        Issue.record("a kernel generation opens with its head")
        return
      }
      #expect(transcript.items.count == 1)
      #expect(head.note == "Back on the kernel.")
      #expect(try await store.generationState(id).generation == 2)
    }
  }
}
