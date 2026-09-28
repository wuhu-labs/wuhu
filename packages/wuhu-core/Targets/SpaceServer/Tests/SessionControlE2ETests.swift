import Foundation
import JSONValue
import SessionDomain
import SpaceCore
import SpaceServer
import Testing

// wuhu:session's operator verbs through the server's real wiring: the MCP
// route's executor, the SessionService behind sessionControl, and the
// session loops themselves. Nothing here fakes SessionControl.
@Suite struct SessionControlE2ETests {
  @Test func anAncestorArchivesAndInterruptsItsDescendantsAndOthersAreRefused() async throws {
    try await withSessionDeps {
      let entered = Gate()
      let release = Gate()
      let harness = try await SessionHarness(inference: { _, _ in
        entered.open()
        await release.wait()
        return reply("done")
      })
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let root = try await harness.createSession(title: "orchestrator")
      let coder = try await harness.store.createSession(
        group: .shared,
        title: "coder", kind: .task, parent: root, createdBy: root.rawValue, executor: model,
      )
      let reviewer = try await harness.store.createSession(
        group: .shared,
        title: "reviewer", kind: .task, parent: coder, createdBy: coder.rawValue, executor: model,
      )
      // A top-level agent is an admin of its group and may archive any
      // session in it; its task may not.
      let strangerAgent = try await harness.createSession(title: "stranger")
      let stranger = try await harness.store.createSession(
        group: .shared,
        title: "stranger's task", kind: .task, parent: strangerAgent, createdBy: strangerAgent.rawValue, executor: model,
      )

      func script(_ caller: SessionID, _ body: String) async throws -> String {
        let result = try await callResult(harness, caller.rawValue, tool: "run_script", .object([
          "source": .string("import { archive, interrupt } from \"wuhu:session\"\n" + body),
        ]))
        return resultText(result) ?? ""
      }
      let settle = "then(() => \"done\", (error) => error.message)"

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }

        // A grandchild, so the right is the ancestor's, not only the parent's.
        #expect(try await script(root, "result(await archive(\"\(reviewer.rawValue)\").\(settle))").contains("done"))
        guard case .archived = try await harness.store.record(reviewer).lifecycle else {
          Issue.record("the ancestor's archive did not archive the reviewer")
          return
        }

        let refused = try await script(stranger, "result(await archive(\"\(coder.rawValue)\").\(settle))")
        #expect(refused.contains(
          "\(stranger.rawValue) may not archive or unarchive session \(coder.rawValue): only the session itself, its creator and admins of its group may",
        ))
        #expect(try await harness.store.record(coder).lifecycle == .live)

        // Busy: the coder is mid-turn, waiting on its inference.
        try await harness.deliver("start", to: coder)
        await entered.wait()
        let selfArchive = try await script(coder, "result(await archive(\"\(coder.rawValue)\").\(settle))")
        #expect(selfArchive.contains("can't archive itself mid-turn"), "\(selfArchive)")
        #expect(selfArchive.contains("its parent, an ancestor or a human archives it"))
        #expect(try await harness.store.record(coder).lifecycle == .live)

        #expect(try await script(root, "result(await interrupt(\"\(coder.rawValue)\").\(settle))").contains("done"))
        #expect(try await harness.store.record(coder).hold == .interrupted)
        release.open()
      }
    }
  }
}
