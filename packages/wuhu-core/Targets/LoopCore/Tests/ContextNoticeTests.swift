import ClaudeStream
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import struct WuhuAI.ToolCall

@Suite struct ContextNoticeTests {
  @Test func `a tool call that touched a repository is followed by its context notice`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let repo = "machines://m1/repo"
      let script = InferenceScript([
        Fix.replying("reading", calls: [
          ToolCall(id: "call_0", name: "read", arguments: .object(["path": .string(repo + "/a")])),
          ToolCall(id: "call_1", name: "read", arguments: .object(["path": .string(repo + "/b")])),
        ]),
        Fix.replying("done"),
      ])
      let executed = ExecScript { call in
        if call.arguments == .object(["path": .string(repo + "/a")]) {
          try await sessions.recordScopeContext(
            sid,
            toolCallID: ToolCallID(call.id),
            context: ScopeContext(folders: [repo: repo], text: "repo manual"),
          )
        }
        return .read(.init(path: repo, revision: .journal(1), content: call.id))
      }
      let config = makeConfig(executeTool: { try await executed($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("second assistant reply") {
          try await sessions.hydrate(sid).transcript.kernel.assistantEntries.count == 2
        }
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      let shape = transcript.items.compactMap { item -> String? in
        switch item {
        case let .toolResult(result): "result \(result.payload.renderedText)"
        case let .notification(notice) where notice.kind == .context: "context \(notice.content.text)"
        default: nil
        }
      }
      let ids = executed.calls.value.map(\.id)
      #expect(shape == ["result \(ids[0])", "context repo manual", "result \(ids[1])"])
      let expected: [String: String?] = [repo: repo]
      #expect(transcript.environment.tools.folderRoots == expected)
    }
  }

  @Test func `the after-tool hook returns the context recorded for its tool call, ahead of pending messages`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let parked = Box(false)
      let never = Latch()
      let fake = FakeClaudeCode(cue: { cue in
        if cue.line.contains(#""subtype":"hook_started""#), cue.line.contains(#""hook_event":"Stop""#) {
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
        try await sessions.recordScopeContext(
          sid,
          toolCallID: ToolCallID("toolu_ctx"),
          context: ScopeContext(folders: ["machines://m1/repo": "machines://m1/repo"], text: "repo manual"),
        )
        let activation = fake.launches.value[0].activation
        let other = await service.claudeCodeHook(sid, activation: activation, body: ["hook_event_name": "PostToolUse", "tool_use_id": "toolu_other"])
        #expect(other == [:])

        let hook: JSONValue = ["hook_event_name": "PostToolUse", "tool_use_id": "toolu_ctx"]
        let alone = try #require(await service.claudeCodeHook(sid, activation: activation, body: hook).additionalContext)
        #expect(alone.contains("<type>system notice</type>"))
        #expect(alone.hasSuffix("\n\nrepo manual"))

        _ = try await service.enqueue(item: Fix.message("meanwhile", message: "m2"), to: sid)
        let both = try #require(await service.claudeCodeHook(sid, activation: activation, body: hook).additionalContext)
        let manual = try #require(both.range(of: "repo manual"))
        let message = try #require(both.range(of: "meanwhile"))
        #expect(manual.upperBound < message.lowerBound)
        try await service.interrupt(sid)
      }
    }
  }
}
