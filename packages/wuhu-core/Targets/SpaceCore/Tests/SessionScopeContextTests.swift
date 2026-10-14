import GRDB
import SessionDomain
@testable import SpaceCore
import Testing

struct SessionScopeContextTests {
  @Test func legacyStagedFoldersRemainReadableWithoutHashes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let session = try await space.sessions.createSession(group: .shared, title: "old", kind: .agent, createdBy: "morgan", model: .test)
      try await space.writer.write { db in
        try db.execute(sql: "INSERT INTO session_scope_context (session_id, tool_call_id, folders, text) VALUES (?, 'old-call', ?, 'old manual')", arguments: [session.rawValue, #"{"machines://m1/repo":"machines://m1/repo"}"#])
      }
      let staged = try await space.sessions.scopeContext(session, toolCallID: ToolCallID("old-call"))
      #expect(staged == ScopeContext(folders: ["machines://m1/repo": "machines://m1/repo"], text: "old manual"))
    }
  }

  @Test func aRecordedContextReadsBackPerSessionAndToolCall() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let one = try await store.createSession(group: .shared, title: "one", kind: .agent, createdBy: "morgan", model: .test)
      let two = try await store.createSession(group: .shared, title: "two", kind: .agent, createdBy: "morgan", model: .test)
      let context = ScopeContext(folders: ["machines://m1/repo": "machines://m1/repo", "machines://m1/tmp": nil], deliveredContext: ["hash": "machines://m1/repo/AGENTS.md"], text: "repo manual")
      try await store.recordScopeContext(one, toolCallID: ToolCallID("c1"), context: context)

      #expect(try await store.scopeContext(one, toolCallID: ToolCallID("c1")) == context)
      #expect(try await store.scopeContext(one, toolCallID: ToolCallID("c2")) == nil)
      #expect(try await store.scopeContext(two, toolCallID: ToolCallID("c1")) == nil)

      let retried = ScopeContext(folders: ["machines://m1/other": nil], text: "")
      try await store.recordScopeContext(one, toolCallID: ToolCallID("c1"), context: retried)
      #expect(try await store.scopeContext(one, toolCallID: ToolCallID("c1")) == retried)
    }
  }
}
