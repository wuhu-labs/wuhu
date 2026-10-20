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
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let repo = "machines://m1/repo"
      let script = InferenceScript([
        Fix.replying("reading", calls: [
          ToolCall(id: "call_0", name: "read", arguments: .object(["path": .string(repo + "/a")])),
          ToolCall(id: "call_1", name: "read", arguments: .object(["path": .string(repo + "/b")])),
        ]),
        Fix.replying("done"),
      ])
      let calls = Box<[ToolCall]>([])
      var config = makeConfig(inference: { try await script($0) })
      config.executeTool = { invocation in
        let call = invocation.call
        calls.withLock { $0.append(call) }
        let payload = ToolResultPayload.read(.init(path: repo, revision: .journal(1), content: call.id))
        guard call.arguments == .object(["path": .string(repo + "/a")]) else { return ToolOutcome(payload: payload) }
        return ToolOutcome(
          payload: payload,
          context: ScopeContext(folders: [repo: repo], deliveredContext: ["hash": repo + "/AGENTS.md"], text: "repo manual"),
        )
      }

      try await runService(space, config) { service in
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
      let ids = calls.value.map(\.id)
      #expect(shape == ["result \(ids[0])", "context repo manual", "result \(ids[1])"])
      let expected: [String: String?] = [repo: repo]
      #expect(transcript.environment.tools.folderRoots == expected)
      #expect(transcript.environment.tools.deliveredContext == ["hash": repo + "/AGENTS.md"])
    }
  }
}
