import ClaudeStream
import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct ClaudeCodeLoopTests {
  private static func isMirror(_ line: String) -> Bool { line.contains(#""type":"transcript_mirror""#) }
  private static func isHook(_ line: String, _ event: String) -> Bool {
    line.contains(#""subtype":"hook_started""#) && line.contains(#""hook_event":"\#(event)""#)
  }

  @Test func `a delivery goes in on standard input and drains when the mirror records it`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let flushed = Latch()
      let fake = FakeClaudeCode(cue: { cue in
        if cue.turn == 0, Self.isMirror(cue.line) { await flushed.wait(unless: cue.killed) }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("hello", conversation: sid.rawValue, owesReply: true), to: sid)
        try await until("the delivery is written") { fake.writes.value.count == 1 }
        #expect(fake.launches.value.map(\.log.entries.isEmpty) == [true])
        let texts = fake.writtenTexts[0]
        #expect(texts.count == 1)
        #expect(texts[0].hasPrefix("[standardInput] <sender>morgan</sender>"))
        #expect(texts[0].hasSuffix("<message-id>m1</message-id>\n\nhello"))

        // The capture's first tool call answers in the box, as its receipt records.
        try await sessions.recordReceipt(sid, toolCallID: ToolCallID("toolu_p001"), payload: .sendMessage(.init(
          messageID: MessageID("a1"), conversationID: ConversationID(sid.rawValue), n: 1,
        )))
        await time.advance(by: 1)
        #expect(try await sessions.undrainedInputs(sid).count == 1)
        #expect(try await sessions.record(sid).work == .hasWork)

        flushed.release()
        try await until("the turn settles") { try await sessions.settledWork(sid) }
        #expect(try await sessions.undrainedInputs(sid).isEmpty)
        try await holds("no nag: the reply is in the log") { fake.writes.value.count == 1 }
      }
      #expect(fake.hookReplies.value == [[:], [:], [:]])
      let uuid = fake.writes.value[0].object?["uuid"]?.stringValue
      let log = try await sessions.claudeCodeLog(sid)
      #expect(log.entries.contains { $0["type"] == "user" && $0["uuid"]?.stringValue == uuid })
    }
  }

  // With `failed`, the capture's tool calls replay as failed ones: Claude Code
  // then calls PostToolUseFailure instead, and logs its handover under that event.
  @Test(arguments: [false, true])
  func `a message arriving mid-turn goes in through the after-each-tool hook`(failed: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let atSecondHook = Latch()
      let beforeSecondFlush = Latch()
      let reached = Box<[String]>([])
      let postToolHooks = Box(0)
      let mirrors = Box(0)
      let fake = FakeClaudeCode(
        cue: { cue in
          if Self.isHook(cue.line, "PostToolUse"), postToolHooks.withLock({ $0 += 1; return $0 }) == 2 {
            reached.withLock { $0.append("second hook") }
            await atSecondHook.wait(unless: cue.killed)
          }
          if Self.isMirror(cue.line), mirrors.withLock({ $0 += 1; return $0 }) == 2 {
            reached.withLock { $0.append("second flush") }
            await beforeSecondFlush.wait(unless: cue.killed)
          }
          return .proceed
        },
        rewrite: { _, line in
          guard failed else { return line }
          return line.replacingOccurrences(of: #"PostToolUse""#, with: #"PostToolUseFailure""#)
            .replacingOccurrences(of: "PostToolUse:", with: "PostToolUseFailure:")
        },
        hookBody: { _, body in
          guard failed, var fields = body.object, fields["hook_event_name"] == "PostToolUse" else { return body }
          fields["hook_event_name"] = "PostToolUseFailure"
          fields["tool_response"] = nil
          fields["error"] = "The operation timed out."
          return .object(fields)
        },
      )
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("start"), to: sid)
        try await until("the turn reaches its second tool call") { reached.value == ["second hook"] }
        try await until("the first flush is recorded") { try await service.flushRecorded(sessions, sid) }
        _ = try await service.enqueue(item: Fix.message("meanwhile", message: "m2"), to: sid)
        atSecondHook.release()
        try await until("the hook has answered") { reached.value == ["second hook", "second flush"] }
        #expect(fake.hookReplies.value.count == 3)
        #expect(fake.hookReplies.value[0] == [:], "the first hook ran before the log recorded the standard-input handover")
        #expect(fake.hookReplies.value[2] == [:], "the end-of-turn hook hands over nothing while the tool hook's handover is outstanding")
        let handed = try #require(fake.hookReplies.value[1].additionalContext)
        #expect(handed.hasPrefix("[hook] <sender>morgan</sender>"))
        #expect(handed.hasSuffix("<message-id>m2</message-id>\n\nmeanwhile"))
        #expect(fake.hookReplies.value[1] == ["hookSpecificOutput": [
          "hookEventName": .string(failed ? "PostToolUseFailure" : "PostToolUse"), "additionalContext": .string(handed),
        ]])
        #expect(try await sessions.undrainedInputs(sid).count == 1, "handed over, not yet recorded")

        beforeSecondFlush.release()
        try await until("the turn settles") { try await sessions.settledWork(sid) }
        #expect(try await sessions.undrainedInputs(sid).isEmpty)
        try await holds("nothing goes again") { fake.writes.value.count == 1 }
      }
    }
  }

  @Test func `a message arriving during a turn without tools goes in through the end-of-turn hook, once`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let atStop = Latch()
      let reached = Box(false)
      let fake = FakeClaudeCode(cue: { cue in
        if cue.turn == 1, Self.isHook(cue.line, "Stop"), !reached.value {
          reached.withLock { $0 = true }
          await atStop.wait(unless: cue.killed)
        }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the first turn settles") { try await sessions.settledWork(sid) && fake.writes.value.count == 1 }
        _ = try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await until("the second turn reaches its end") { reached.value }
        try await until("its flush is recorded") { try await service.flushRecorded(sessions, sid) }
        _ = try await service.enqueue(item: Fix.message("three", message: "m3"), to: sid)
        atStop.release()
        try await until("the turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        #expect(try await sessions.undrainedInputs(sid).isEmpty)
        try await holds("nothing goes again") { fake.writes.value.count == 2 }
      }
      let replies = fake.hookReplies.value
      let handed = try #require(replies[3].additionalContext)
      #expect(handed.hasSuffix("<message-id>m3</message-id>\n\nthree"))
      #expect(replies[3] == ["hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": .string(handed)]])
      #expect(replies[4] == [:], "the re-entered end-of-turn hook nags no more")
    }
  }

  @Test func `a process that exits mid-turn is resumed from the stored log and told to continue`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [1]], cue: { cue in
        cue.launch == 0 && Self.isHook(cue.line, "Stop") ? .exit("exit status 1") : .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the process has exited") { fake.launches.value.count == 1 && fake.writes.value.count == 1 }
        try await holds("the first continuation waits a second") { fake.launches.value.count == 1 }
        try await time.wake("the continuation", after: 1)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      let resumed = fake.launches.value[1]
      #expect(!resumed.log.entries.isEmpty, "the second process resumes from what the mirror stored")
      #expect(resumed.log.sessionID == fake.launches.value[0].log.sessionID)
      let continuation = fake.writtenTexts[1]
      #expect(continuation.count == 1, "the delivery was recorded before the exit; only the notice goes")
      #expect(continuation[0].contains("<source>session.continuation</source>\n<type>system notice</type>"))
      #expect(continuation[0].hasSuffix(
        "Wuhu restarted Claude Code: your previous turn ended before it finished (the Claude Code process exited: exit status 1). Continue from where you left off.",
      ))
    }
  }

  @Test func `consecutive cut-offs back off and then error the session`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [0], [0]], cue: { _ in .exit("exit status 1") })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the first process has exited") { fake.writes.value.count == 1 }
        try await holds("the first continuation waits a second") { fake.writes.value.count == 1 }
        try await time.wake("the first continuation", after: 1)
        try await until("the second attempt") { fake.writes.value.count == 2 }
        try await holds("the second waits two") { fake.writes.value.count == 2 }
        try await time.wake("the second continuation", after: 2)
        try await until("the third attempt") { fake.writes.value.count == 3 }
        try await until("the session errors") { try await sessions.record(sid).work == .errored }
      }
      #expect(try await sessions.record(sid).errorMessage?.contains("ended 3 turns in a row before they finished") == true)
      #expect(fake.writtenTexts[1].count == 2, "an unrecorded delivery goes again, after the notice")
    }
  }

  @Test func `an errored result errors the session with Claude Code's own reason, and resume continues it`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let refusal = "API Error: 400 Claude Code 2.1.272 does not support this model; version 2.1.280 or newer is required."
      let fake = FakeClaudeCode(turnsPerLaunch: [[0, 1]], rewrite: { turn, line in
        guard turn == 0, var frame = JSONValue.parse(line)?.object, frame["type"] == "result" else { return line }
        frame["is_error"] = true
        frame["result"] = .string(refusal)
        return JSONValue.object(frame).jsonString()
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the session errors") { try await sessions.record(sid).work == .errored }
        #expect(try await sessions.record(sid).errorMessage == "Claude Code ended the turn with an error: \(refusal)")
        try await service.resume(sid)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      #expect(fake.launches.value.count == 1, "the process outlived the errored turn")
      #expect(fake.writtenTexts[1].first?.hasSuffix(
        "(it ended with an error: Claude Code ended the turn with an error: \(refusal)). Continue from where you left off.",
      ) == true)
    }
  }

  @Test func `a failed result without text takes its reason from the stored API error entry`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let refusal = "API Error: 400 Claude Code 2.1.272 does not support this model; version 2.1.280 or newer is required."
      let fake = FakeClaudeCode(rewrite: { turn, line in
        guard turn == 0, var frame = JSONValue.parse(line)?.object else { return line }
        if frame["type"] == "result" {
          frame["is_error"] = true
          frame["result"] = nil
          return JSONValue.object(frame).jsonString()
        }
        guard frame["type"] == "transcript_mirror", var entries = frame["entries"]?.array,
              let last = entries.lastIndex(where: { $0.object?["type"] == "assistant" }),
              var entry = entries[last].object, var message = entry["message"]?.object
        else { return line }
        entry["isApiErrorMessage"] = true
        message["content"] = [["type": "text", "text": .string(refusal)]]
        entry["message"] = .object(message)
        entries[last] = .object(entry)
        frame["entries"] = .array(entries)
        return JSONValue.object(frame).jsonString()
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the session errors") { try await sessions.record(sid).work == .errored }
      }
      #expect(try await sessions.record(sid).errorMessage == "Claude Code ended the turn with an error: \(refusal)")
    }
  }

  @Test func `a malformed mirror frame errors the session`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(rewrite: { _, line in
        Self.isMirror(line) ? #"{"type":"transcript_mirror","entries":"broken"}"# : line
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the session errors") { try await sessions.record(sid).work == .errored }
      }
      #expect(try await sessions.record(sid).errorMessage?.hasPrefix("Claude Code sent a frame Wuhu cannot read") == true)
    }
  }

  @Test func `interrupt kills the process, and resume continues the cut turn`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let never = Latch()
      let parked = Box(false)
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [1]], cue: { cue in
        if cue.launch == 0, Self.isHook(cue.line, "Stop") {
          parked.withLock { $0 = true }
          await never.wait(unless: cue.killed)
        }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the turn is running") { parked.value }
        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).hold == .interrupted)
        #expect(try await sessions.record(sid).work == .hasWork, "the cut turn stays on record")
        try await holds("nothing restarts while interrupted") { fake.launches.value.count == 1 }
        try await service.resume(sid)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      #expect(fake.writtenTexts[1] == [fake.writtenTexts[1][0]])
      #expect(fake.writtenTexts[1][0].hasSuffix("(it was interrupted). Continue from where you left off."))
    }
  }

  @Test func `an interrupted turn outlives its session's retirement, and resume continues it`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let never = Latch()
      let parked = Box(false)
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [1]], cue: { cue in
        if cue.launch == 0, Self.isHook(cue.line, "Stop") {
          parked.withLock { $0 = true }
          await never.wait(unless: cue.killed)
        }
        return .proceed
      })
      let eviction = EvictionPolicy(idleTTL: .seconds(10), maxIdle: 32, sweepInterval: .seconds(5))
      try await runService(sessions, makeClaudeCodeConfig(fake, eviction: eviction)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the turn is running") { parked.value }
        try await service.interrupt(sid)
        try await until("idle") { await service.registry.sessions[sid]?.idleSince != nil }
        try await until("retired") {
          guard await service.registry.sessions[sid] != nil else { return true }
          try await time.wake("the reaper", after: 5)
          return false
        }
        #expect(try await sessions.record(sid).work == .hasWork)
        try await service.resume(sid)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      let texts = fake.writtenTexts
      try #require(texts.count == 2)
      #expect(texts[1].count == 1)
      #expect(texts[1].first?.hasSuffix("(it was interrupted). Continue from where you left off.") == true)
    }
  }

  @Test func `an interrupted turn outlives a server restart, and resume continues it`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let never = Latch()
      let parked = Box(false)
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [1]], cue: { cue in
        if cue.launch == 0, Self.isHook(cue.line, "Stop") {
          parked.withLock { $0 = true }
          await never.wait(unless: cue.killed)
        }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the turn is running") { parked.value }
        try await service.interrupt(sid)
      }
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        try await holds("nothing starts while interrupted") { fake.launches.value.count == 1 }
        try await service.resume(sid)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      let texts = fake.writtenTexts
      try #require(texts.count == 2)
      #expect(texts[1].count == 1)
      #expect(texts[1].first?.hasSuffix("(it was interrupted). Continue from where you left off.") == true)
    }
  }

  @Test func `a message queued during the cut turn goes in with the continuation on resume`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let never = Latch()
      let parked = Box(false)
      let fake = FakeClaudeCode(turnsPerLaunch: [[0], [1]], cue: { cue in
        if cue.launch == 0, Self.isHook(cue.line, "Stop") {
          parked.withLock { $0 = true }
          await never.wait(unless: cue.killed)
        }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the turn is running") { parked.value }
        _ = try await service.enqueue(item: Fix.message("meanwhile", message: "m2"), to: sid)
        try await service.interrupt(sid)
        #expect(try await sessions.record(sid).work == .hasWork, "the queued message is still work")
        try await holds("it waits for the resume") { fake.writes.value.count == 1 }
        try await service.resume(sid)
        try await until("the continuation is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
        #expect(try await sessions.undrainedInputs(sid).isEmpty)
      }
      let texts = fake.writtenTexts
      try #require(texts.count == 2)
      #expect(texts[1].first?.hasSuffix("(it was interrupted). Continue from where you left off.") == true)
      #expect(texts[1].joined().hasSuffix("<message-id>m2</message-id>\n\nmeanwhile"))
    }
  }

  @Test func `a session found mid-turn at boot is continued`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      try await sessions.beginClaudeCodeTurn(sid)
      let fake = FakeClaudeCode()
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        try await until("the continuation is written") { fake.writes.value.count == 1 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      #expect(fake.writtenTexts[0].first?.hasSuffix("(Wuhu restarted while it ran). Continue from where you left off.") == true)
    }
  }

  @Test func `a restart's note goes in ahead of the first delivery and clears when recorded`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let before = try await sessions.claudeCodeLog(sid).sessionID
      try await sessions.restart(sid, note: "Started over.")
      #expect(try await sessions.claudeCodeLog(sid).sessionID != before)
      let flushed = Latch()
      let fake = FakeClaudeCode(cue: { cue in
        if Self.isMirror(cue.line) { await flushed.wait(unless: cue.killed) }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        try await holds("a restart alone starts nothing") { fake.launches.value.isEmpty }
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("the delivery is written") { fake.writes.value.count == 1 }
        #expect(try await sessions.claudeCodePendingNote(sid) == "Started over.")
        flushed.release()
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      #expect(try await sessions.claudeCodePendingNote(sid) == nil)
      let texts = fake.writtenTexts[0]
      #expect(texts.count == 2)
      #expect(texts[0].contains("<source>session.restart</source>\n<type>system notice</type>\n\nStarted over."))
      #expect(texts[1].hasSuffix("hello"))
    }
  }

  @Test func `a hook from anything but the running activation hands nothing over`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let parked = Box(false)
      let never = Latch()
      let fake = FakeClaudeCode(cue: { cue in
        if Self.isHook(cue.line, "Stop") {
          parked.withLock { $0 = true }
          await never.wait(unless: cue.killed)
        }
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the turn is running") { parked.value }
        try await until("its flush is recorded") { try await service.flushRecorded(sessions, sid) }
        _ = try await service.enqueue(item: Fix.message("waiting", message: "m2"), to: sid)
        let stop: JSONValue = ["hook_event_name": "Stop", "stop_hook_active": false]
        #expect(await service.claudeCodeHook(sid, activation: UUID(), body: stop) == [:])
        #expect(await service.claudeCodeHook(SessionID("nobody"), activation: UUID(), body: stop) == [:])
        #expect(await service.claudeCodeHook(sid, activation: fake.launches.value[0].activation, body: ["hook_event_name": "Notification"]) == [:])
        let live = await service.claudeCodeHook(sid, activation: fake.launches.value[0].activation, body: stop)
        #expect(live.additionalContext?.hasSuffix("waiting") == true)
        #expect(await service.claudeCodeHook(sid, activation: fake.launches.value[0].activation, body: stop) == [:], "one handover outstanding at a time")
        try await service.interrupt(sid)
      }
    }
  }

  @Test func `an idle process is ended before its session retires, and the next delivery resumes`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode()
      let eviction = EvictionPolicy(idleTTL: .seconds(10), maxIdle: 32, sweepInterval: .seconds(5))
      try await runService(sessions, makeClaudeCodeConfig(fake, eviction: eviction)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("the turn settles") { try await sessions.settledWork(sid) && fake.writes.value.count == 1 }
        // The idle clock starts only once the loop pass has ended, and the
        // process ends between sweeps: advancing ahead of either sweeps a
        // session that does not look idle yet.
        try await until("idle") { await service.registry.sessions[sid]?.idleSince != nil }
        try await until("retired") {
          guard await service.registry.sessions[sid] != nil else { return true }
          try await time.wake("the reaper", after: 5)
          return false
        }
        _ = try await service.enqueue(item: Fix.message("two", message: "m2"), to: sid)
        try await until("the second delivery is written") { fake.writes.value.count == 2 }
        try await until("the turn settles") { try await sessions.settledWork(sid) }
      }
      let launches = fake.launches.value
      try #require(launches.count == 2)
      #expect(launches[0].log.entries.isEmpty)
      #expect(!launches[1].log.entries.isEmpty, "the second process resumes the conversation")
    }
  }
}
