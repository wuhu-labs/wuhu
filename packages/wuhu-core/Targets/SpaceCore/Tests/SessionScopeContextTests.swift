import SessionDomain
import SpaceCore
import Testing

struct SessionScopeContextTests {
  @Test func aRecordedContextReadsBackPerSessionAndToolCall() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let one = try await store.createSession(group: .shared, title: "one", kind: .agent, createdBy: "morgan", model: .test)
      let two = try await store.createSession(group: .shared, title: "two", kind: .agent, createdBy: "morgan", model: .test)
      let context = ScopeContext(folders: ["machines://m1/repo": "machines://m1/repo", "machines://m1/tmp": nil], text: "repo manual")
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
