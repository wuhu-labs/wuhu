import ClaudeStream
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct ClaudeCodeCompactionTests {
  private static func isHook(_ line: String, _ event: String) -> Bool {
    line.contains(#""subtype":"hook_started""#) && line.contains(#""hook_event":"\#(event)""#)
  }

  private static func isAssistant(_ line: String) -> Bool { line.hasPrefix(#"{"type":"assistant""#) }

  // What Claude Code prints when it compacts: the boundary on the stream,
  // then the mirror frame holding it, the summary and whatever follows.
  private static func compaction(_ id: String, trigger: String = "auto", after: [JSONValue] = []) -> [String] {
    let entries: [JSONValue] = [
      ["type": "system", "subtype": "compact_boundary", "uuid": .string(id), "compactMetadata": ["trigger": .string(trigger), "preTokens": 900]],
      ["type": "user", "uuid": .string(id + "-summary"), "isCompactSummary": true, "message": ["role": "user", "content": "Summary."]],
    ] + after
    return [
      JSONValue.object([
        "type": "system", "subtype": "compact_boundary", "session_id": "s", "uuid": .string(id),
        "compact_metadata": ["trigger": .string(trigger), "pre_tokens": 900, "post_tokens": 100],
      ]).jsonString(),
      JSONValue.object(["type": "transcript_mirror", "filePath": "/log.jsonl", "entries": .array(entries)]).jsonString(),
    ]
  }

  private static func notice(_ sid: SessionID) -> String { SessionPrompt.compactionNudge(session: sid) }

  @Test func `a compaction mid-turn hands its notice over alone at the next after-each-tool hook`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let assistants = Box(0)
      let postToolHooks = Box(0)
      let fake = FakeClaudeCode(cue: { cue in
        if cue.turn == 0, Self.isHook(cue.line, "PostToolUse"), postToolHooks.withLock({ $0 += 1; return $0 }) == 2 {
          try? await until("the boundary is stored") { try await sessions.claudeCodeOwedCompactionNotice(sid) != nil }
        }
        return .proceed
      }, rewrite: { turn, line in
        guard turn == 0, Self.isAssistant(line), assistants.withLock({ $0 += 1; return $0 }) == 2 else { return line }
        return (Self.compaction("cb-1") + [line]).joined(separator: "\n")
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 3 }
        #expect(try await sessions.claudeCodeOwedCompactionNotice(sid) == nil, "the mirror recorded the hook's handover")

        _ = try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await until("the next turn settles") { try await sessions.settledWork(sid) && fake.writes.value.count == 2 }
      }
      let replies = fake.hookReplies.value
      #expect(replies[0] == [:])
      let handed = try #require(replies[1].additionalContext)
      #expect(handed.contains("session.compaction"))
      #expect(handed.hasSuffix("\n\n" + Self.notice(sid)), "the notice alone, under a system header")
      #expect(replies[2] == [:], "the end-of-turn hook waits for the notice's record")
      #expect(fake.writtenTexts[1].count == 1, "a notice goes once")
      #expect(try await sessions.claudeCodeLog(sid).entries.first?["uuid"] == "cb-1", "the boundary opened the generation")
    }
  }

  @Test func `a compaction at the end of a turn hands its notice over at the end-of-turn hook, keeping the turn going`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let assistants = Box(0)
      let stops = Box(0)
      let fake = FakeClaudeCode(cue: { cue in
        if cue.turn == 1, Self.isHook(cue.line, "Stop"), stops.withLock({ $0 += 1; return $0 }) == 1 {
          try? await until("the boundary is stored") { try await sessions.claudeCodeOwedCompactionNotice(sid) != nil }
        }
        return .proceed
      }, rewrite: { turn, line in
        guard turn == 1, Self.isAssistant(line), assistants.withLock({ $0 += 1; return $0 }) == 1 else { return line }
        return (Self.compaction("cb-1") + [line]).joined(separator: "\n")
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the first turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 3 }
        _ = try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await until("the second turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        #expect(try await sessions.claudeCodeOwedCompactionNotice(sid) == nil)
      }
      let replies = fake.hookReplies.value
      let handed = try #require(replies[3].additionalContext)
      #expect(replies[3] == ["hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": .string(handed)]])
      #expect(handed.hasSuffix("\n\n" + Self.notice(sid)))
      #expect(replies[4] == [:], "the re-entered end-of-turn hook ends the turn")
    }
  }

  @Test(arguments: ["auto", "manual"])
  func `a notice every hook of its turn missed goes in alone after the result, if the compaction came in that turn`(trigger: String) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(rewrite: { turn, line in
        guard turn == 0, JSONValue.parse(line)?.object?["type"] == "result" else { return line }
        return (Self.compaction("cb-1", trigger: trigger) + [line]).joined(separator: "\n")
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        guard trigger == "auto" else {
          try await until("the turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 3 }
          try await holds("a compaction outside a turn waits for the next delivery") { fake.writes.value.count == 1 }
          #expect(try await sessions.claudeCodeOwedCompactionNotice(sid) == .manual)
          return
        }
        try await until("the notice is written") { fake.writes.value.count == 2 }
        try await until("its turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        #expect(try await sessions.claudeCodeOwedCompactionNotice(sid) == nil)
      }
      guard trigger == "auto" else { return }
      #expect(fake.writtenTexts[1].count == 1)
      #expect(fake.writtenTexts[1][0].hasSuffix("\n\n" + Self.notice(sid)))
    }
  }

  @Test(arguments: [false, true])
  func `the notice lists the timers and observations still armed, and nothing once they are cancelled`(cancelled: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      try await sessions.armSubscriptions(sid)
      if cancelled { try await sessions.cancelSubscriptions(sid) }
      let fake = FakeClaudeCode(rewrite: { turn, line in
        guard turn == 0, JSONValue.parse(line)?.object?["type"] == "result" else { return line }
        return (Self.compaction("cb-1") + [line]).joined(separator: "\n")
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the notice is written") { fake.writes.value.count == 2 }
        try await until("its turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
      }
      let notice = try #require(fake.writtenTexts[1].first)
      let expected = cancelled ? Self.notice(sid) : Self.notice(sid) + "\n\n" + armedSubscriptionsListing
      #expect(notice.hasSuffix("\n\n" + expected))
    }
  }

  @Test func `a requested compaction waits for the turn, writes the command, and the next delivery carries the notice`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let compacting = Latch()
      let reached = Box(false)
      let fake = FakeClaudeCode(cue: { cue in
        if cue.turn == -1, cue.line.hasPrefix(#"{"type":"result""#) {
          reached.withLock { $0 = true }
          await compacting.wait(unless: cue.killed)
        }
        return .proceed
      }, command: { line in
        guard let text = line.object?["message"]?.object?["content"]?.array?.first?.object?["text"]?.stringValue,
              text.hasPrefix("/compact"), let uuid = line.object?["uuid"]
        else { return nil }
        let command: JSONValue = ["type": "user", "uuid": uuid, "message": ["role": "user", "content": .string(text)]]
        return Self.compaction("cb-1", trigger: "manual", after: [command])
          + [#"{"type":"result","subtype":"success","is_error":false,"result":"","num_turns":0,"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}"#]
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the turn has started") { fake.writes.value.count == 1 }
        try await sessions.requestCommand(sid, .compact(instructions: "keep the plan"))
        try await until("the turn settles") { try await sessions.settledWork(sid) }
        try await until("the command is written") { fake.writes.value.count == 2 }
        #expect(fake.writtenTexts[1] == ["/compact keep the plan"])
        #expect(try await sessions.pendingCommand(sid) == nil)

        try await until("the compaction runs") { reached.value }
        #expect(try await sessions.record(sid).work == .noWork, "steering, not work")
        _ = try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await holds("nothing else goes in while it compacts") { fake.writes.value.count == 2 }

        compacting.release()
        try await until("the delivery is written") { fake.writes.value.count == 3 }
        try await until("its turn settles") { try await sessions.settledWork(sid) }
        #expect(try await sessions.claudeCodeOwedCompactionNotice(sid) == nil)
      }
      #expect(fake.launches.value.count == 1, "no restart")
      let texts = fake.writtenTexts[2]
      #expect(texts.count == 2)
      #expect(texts[0].hasSuffix("\n\n" + Self.notice(sid)))
      #expect(texts[1].hasSuffix("<message-id>m2</message-id>\n\ntwo"))
    }
  }

  @Test func `a requested compaction of a session with no log is dropped without starting Claude Code`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode()
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        try await sessions.requestCommand(sid, .compact(instructions: nil))
        try await until("the command is taken") { try await sessions.pendingCommand(sid) == nil }
        try await holds("nothing starts") { fake.launches.value.isEmpty }
      }
    }
  }
}
