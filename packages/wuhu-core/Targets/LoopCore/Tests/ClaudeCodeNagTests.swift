import ClaudeStream
import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct ClaudeCodeNagTests {
  private static func isMirror(_ line: String) -> Bool { line.contains(#""type":"transcript_mirror""#) }
  private static func isHook(_ line: String, _ event: String) -> Bool {
    line.contains(#""subtype":"hook_started""#) && line.contains(#""hook_event":"\#(event)""#)
  }

  @Test func `the end-of-turn gate nags an unanswered delivery once, and the log records it`() async throws {
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
        _ = try await service.enqueue(item: Fix.message("please answer", message: "m2", conversation: sid.rawValue, owesReply: true), to: sid)
        try await until("the second turn reaches its end") { reached.value }
        try await until("its delivery is recorded") { try await service.flushRecorded(sessions, sid) }
        atStop.release()
        try await until("the turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        try await holds("no nag on standard input: the gate's is recorded") { fake.writes.value.count == 2 }
      }
      let replies = fake.hookReplies.value
      #expect(replies[0 ..< 3].allSatisfy { $0 == [:] }, "nothing owed in the first turn")
      let nag = try #require(replies[3].additionalContext)
      #expect(nag.hasPrefix("<sender>system</sender>"))
      #expect(nag.contains("<source>owed.reply</source>\n<type>owed reply</type>\n\n"))
      #expect(nag.hasSuffix(SessionPrompt.owedReply(conversations: [sid.rawValue])))
      #expect(replies[4] == [:], "the re-entered stop ends the turn")
      #expect(try await sessions.claudeCodeEnvironment(sid).nag(task: false, now: anchor) == nil, "reminded once")
    }
  }

  @Test func `a fast turn that ends unanswered is nagged on standard input after its result`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      // run5's first turn with its log flushed after the end-of-turn hook, as
      // a fast turn flushes: every hook of the turn sees the delivery unrecorded.
      let fake = FakeClaudeCode(deferred: { turn, line in turn == 0 && Self.isMirror(line) })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("please answer", conversation: sid.rawValue, owesReply: true), to: sid)
        try await until("the nag goes in on standard input") { fake.writes.value.count == 2 }
        try await until("its turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        try await holds("nagged once") { fake.writes.value.count == 2 }
      }
      #expect(fake.hookReplies.value.allSatisfy { $0 == [:] })
      let nag = fake.writtenTexts[1]
      #expect(nag.count == 1)
      #expect(nag[0].contains("<source>owed.reply</source>\n<type>owed reply</type>\n\n"))
      #expect(nag[0].hasSuffix(SessionPrompt.owedReply(conversations: [sid.rawValue])))
      #expect(try await sessions.claudeCodeEnvironment(sid).nag(task: false, now: anchor) == nil, "reminded once")
    }
  }

  @Test func `a task that ends with its request open is parked, then woken by nextTimer`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession(kind: .task)
      let fake = FakeClaudeCode(turnsPerLaunch: [[0, 1, 1]], deferred: { turn, line in turn == 0 && Self.isMirror(line) })
      let request = QueueInput.message(.init(
        id: UUID(), messageID: .init("r1"), conversationID: .init("dm"), sender: Fix.sender, timestamp: anchor,
        kind: .request, requestID: .init("r1"), content: .init(text: "do it"),
      ))
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: request, to: sid)
        try await until("the first park reminder goes in") { fake.writes.value.count == 2 }
        try await until("its turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
        try await holds("the next one waits a minute") { fake.writes.value.count == 2 }
        try await time.wake("the park wake", after: 60)
        try await until("the park wake fires") { fake.writes.value.count == 3 }
      }
      for text in [fake.writtenTexts[1][0], fake.writtenTexts[2][0]] {
        #expect(text.contains("<source>park.r1</source>\n<type>park reminder</type>\n\n"))
        #expect(text.hasSuffix(SessionPrompt.parkReminder(request: "r1")))
      }
    }
  }
}

@Suite struct ClaudeCodeLateFlushTests {
  private static func isMirror(_ line: String) -> Bool { line.contains(#""type":"transcript_mirror""#) }

  @Test func `a handover recorded only after its turn's result is drained once and never sent again`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(deferred: { turn, line in turn == 0 && Self.isMirror(line) }, pastResult: true)
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("once"), to: sid)
        try await until("the turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 3 }
        #expect(try await sessions.undrainedInputs(sid).isEmpty)
        try await holds("nothing goes again") { fake.writes.value.count == 1 }
      }
      let log = try await sessions.claudeCodeLog(sid)
      #expect(log.entries.count { $0["type"] == "user" && $0["uuid"]?.stringValue == fake.writes.value[0].object?["uuid"]?.stringValue } == 1)
    }
  }

  @Test func `a handover never recorded goes again once the backstop runs out`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(rewrite: { turn, line in
        turn == 0 && Self.isMirror(line) ? #"{"type":"keep_alive"}"# : line
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        _ = try await service.enqueue(item: Fix.message("lost"), to: sid)
        try await until("the turn has ended") { fake.hookReplies.value.count == 3 }
        try await holds("the handover still blocks the next write") { fake.writes.value.count == 1 }
        #expect(try await sessions.undrainedInputs(sid).count == 1)
        try await time.wake("the backstop", after: 5)
        try await until("it goes again") { fake.writes.value.count == 2 }
        try await until("and is recorded this time") { try await sessions.settledWork(sid) }
      }
      #expect(fake.writtenTexts[1].last?.hasSuffix("lost") == true)
    }
  }
}
