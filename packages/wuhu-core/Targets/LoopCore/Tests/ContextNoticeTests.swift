#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import struct WuhuAI.ToolCall

@Suite struct ContextNoticeTests {
  private struct Path: Decodable {
    var path: String
  }

  @Test func `a scope notice waits behind the turns last tool answer`() async throws {
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
      let shown = Box<ToolExecutionState?>(nil)
      var config = makeConfig(inference: { try await script($0) })
      config.executeTool = { invocation in
        let call = invocation.call
        calls.withLock { $0.append(call) }
        let payload = ToolResultPayload.read(.init(path: repo, revision: .journal(1), content: call.id))
        guard call.arguments == .object(["path": .string(repo + "/a")]) else {
          do {
            #expect(try await sessions.lines(sid).allSatisfy { $0.key != LineKey.scope }, "the notice remains held while another call is pending")
          } catch { Issue.record(error) }
          return ToolOutcome(payload: payload)
        }
        return ToolOutcome(
          payload: payload,
          context: ScopeContext(folders: [repo: repo], deliveredContext: ["hash": repo + "/AGENTS.md"], text: "repo manual"),
        )
      }

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("second assistant reply") {
          try await sessions.lines(sid).assistantLines.count == 2
        }
        let state = try space.worker.cell(SessionCell.ID(sid.rawValue)).shown()
        shown.withLock { $0 = state }
      }

      let lines = try await sessions.lines(sid)
      let relevant = lines.filter { $0.role == .toolResult || $0.key == LineKey.scope }
      let ids = calls.value.map(\.id)
      #expect(relevant.map(\.key) == ids.map { "call:" + $0 } + [LineKey.scope])
      #expect(relevant.map(\.role) == [.toolResult, .toolResult, .user])
      #expect(Array(relevant.prefix(2)).map(\.text) == ids)
      #expect(relevant.last?.text.hasSuffix("\n\nrepo manual") == true)
      let expected: [String: String?] = [repo: repo]
      #expect(shown.value?.folderRoots == expected)
      #expect(shown.value?.deliveredContext == ["hash": repo + "/AGENTS.md"])
    }
  }

  @Test(arguments: [false, true])
  func `a fold keeps the files its kept tail read, and Start over none`(kept: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let repo = "machines://m1/repo"
      func read(_ file: String) -> ToolCall {
        ToolCall(id: "call_" + file, name: "read", arguments: .object(["path": .string(repo + "/" + file)]))
      }
      let script = InferenceScript([
        Fix.replying("marking", calls: [.init(id: "call_m", name: "bookmark", arguments: .object(["name": .string("b")]))]),
        Fix.replying("reading", calls: [read("a")]),
        Fix.replying("reading on", calls: [read("b")]),
        Fix.replying("folding", calls: [.init(id: "call_f", name: "compact", arguments: .object(kept ? ["summary": .string("s"), "bookmark": .string("b")] : ["summary": .string("s")]))]),
        Fix.replying("after the fold"),
        Fix.replying("started over"),
      ])
      var config = makeConfig(inference: { try await script($0) })
      let secondCall = Box<ToolExecutionState?>(nil)
      config.executeTool = { invocation in
        let path = try invocation.call.arguments.decode(Path.self).path
        if path.hasSuffix("/b") { secondCall.withLock { $0 = invocation.state } }
        return ToolOutcome(
          payload: .read(.init(path: path, revision: .mtime(Date(timeIntervalSince1970: 1_700_000_000.123456)), content: path)),
          context: ScopeContext(folders: [repo: path], deliveredContext: ["hash": path + "/AGENTS.md"], text: "manual by " + path),
        )
      }

      let folded = Box<ToolExecutionState?>(nil)
      let restarted = Box<ToolExecutionState?>(nil)
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("go"), to: sid)
        try await until("the new generation stops") { try await sessions.settledWork(sid) && script.count == 5 }
        let tools = try space.worker.cell(SessionCell.ID(sid.rawValue)).shown()
        folded.withLock { $0 = tools }
        _ = try await service.restart(sid, executor: nil, note: nil)
        try await service.enqueue(item: Fix.message("again", message: "m2"), to: sid)
        try await until("the restarted generation stops") { try await sessions.settledWork(sid) && script.count == 6 }
        let state = try space.worker.cell(SessionCell.ID(sid.rawValue)).shown()
        restarted.withLock { $0 = state }
      }

      #expect(secondCall.value?.fileAccessLog == [repo + "/a": .mtime(Date(timeIntervalSince1970: 1_700_000_000.123456))], "a tool call goes by what the generation was shown")
      #expect(secondCall.value?.deliveredContext == ["hash": repo + "/a/AGENTS.md"])
      #expect(secondCall.value?.folderRoots.keys.sorted() == [repo])
      #expect(Set(try #require(folded.value).fileAccessLog.keys) == (kept ? [repo + "/a", repo + "/b"] : []))
      #expect(folded.value?.folderRoots.isEmpty == true)
      #expect(folded.value?.deliveredContext.isEmpty == true)
      #expect(restarted.value?.fileAccessLog.isEmpty == true)
    }
  }
}
