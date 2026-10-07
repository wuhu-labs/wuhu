import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SpaceCore
import SpaceServer
import Testing

// wuhu:session's operator verbs through the server's real wiring: the MCP
// route's executor, the SessionService behind sessionControl, and the
// session loops themselves. Nothing here fakes SessionControl.
@Suite struct SessionControlE2ETests {
  @Test func unreadableResumeExplainsStartOverOnHTTPAndScriptSurfaces() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let caller = try await harness.createSession(title: "caller")
      let bad = try await harness.store.createSession(group: .shared, title: "bad", kind: .task, parent: caller, createdBy: caller.rawValue, executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")), snapshot: .init())
      try await harness.store.markErrored(bad, message: "old failure")
      try await harness.space.writer.write { db in
        try db.execute(sql: "UPDATE session_contents SET payload = '{}' WHERE session_id = ?", arguments: [bad.rawValue])
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        let response = try await harness.post("/v1/session/\(bad.rawValue)/resume", .null)
        #expect(response.status == .conflict)
        let refusal = try await response.text()
        #expect(refusal.contains("cannot load its stored data"))
        #expect(refusal.contains("Start over"))
        let output = try await callResult(harness, caller.rawValue, tool: "run_script", .object([
          "source": .string("import { resume } from \"wuhu:session\"; result(await resume(\"\(bad.rawValue)\").then(() => \"unexpected success\", e => e.message))"),
        ]))
        #expect(resultText(output)?.contains("Start over") == true)
        #expect(try await harness.store.record(bad).work == .errored)
        #expect(try await harness.post("/v1/session/\(bad.rawValue)/restart", .null).status == .ok)
        #expect(try await harness.store.hydrate(bad).record.work == .noWork)
        #expect(try await harness.post("/v1/session/\(bad.rawValue)/resume", .null).status == .ok)
        let old = try await harness.space.writer.read { db in
          try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ? AND payload = '{}' LIMIT 1", arguments: [bad.rawValue])
        }
        #expect(old == "{}")
      }
    }
  }

  @Test func scriptsRefuseForceSelfArchiveAndRejectNonBooleanForce() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let caller = try await harness.createSession(title: "caller")
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        let output = try await callResult(harness, caller.rawValue, tool: "run_script", .object([
          "source": .string("import { archive } from \"wuhu:session\"; result(await archive(\"\(caller.rawValue)\", { force: true }).then(() => \"unexpected success\", e => e.message))"),
        ]))
        #expect(resultText(output)?.contains("can't force-archive itself") == true)
        #expect(try await harness.store.record(caller).lifecycle == .live)
        let malformed = try await callResult(harness, caller.rawValue, tool: "run_script", .object([
          "source": .string("import { archive } from \"wuhu:session\"; result(await archive(\"\(caller.rawValue)\", { force: \"yes\" }).catch(e => e.message))"),
        ]))
        #expect(resultText(malformed)?.contains("force must be a boolean") == true)
        #expect(try await harness.store.record(caller).lifecycle == .live)
      }
    }
  }

  @Test func settledDetachedScriptCanArchiveItsOwnSubtreeWithoutForce() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let root = try await harness.createSession(title: "waiting")
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let child = try await harness.store.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: model)
      let leaf = try await harness.store.createSession(group: .shared, title: "leaf", kind: .task, parent: child, createdBy: child.rawValue, executor: model)
      let independent = try await harness.store.createSession(group: .shared, title: "independent", kind: .agent, createdBy: root.rawValue, executor: model)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        let output = try await callResult(harness, root.rawValue, tool: "run_script", .object([
          "source": .string("""
          import { archive } from "wuhu:session"
          import { observe } from "wuhu:space"
          result("detached")
          for await (const rows of observe`SELECT title FROM sessions WHERE id = '\(root.rawValue)'`) {
            if (rows[0].title === "settled") break
          }
          await archive("\(root.rawValue)")
          """),
        ]))
        #expect(resultText(output)?.contains("detached") == true)
        #expect(try await harness.store.record(root).work == .noWork)
        #expect(try await harness.store.record(root).lifecycle == .live)
        _ = try await harness.store.setTitle(root, to: "settled")
        try await until("detached script archives its own subtree") {
          try await harness.store.record(root).lifecycle != .live
        }
        for id in [root, child, leaf] { #expect(try await harness.store.record(id).lifecycle != .live) }
        #expect(try await harness.store.record(independent).lifecycle == .live)
      }
    }
  }

  @Test func httpArchiveDefaultsToFalseAndRejectsMalformedForce() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(inference: { _, _ in
        try await ContinuousClock().sleep(for: .seconds(3600))
        return reply("done")
      })
      let root = try await harness.createSession(title: "root")
      let child = try await harness.store.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
      _ = try await harness.store.openRequest(on: child, from: root, messageID: .init("http-request"), text: "queued", deadline: nil)
      for body in [JSONValue.null, .object([:]), .object(["force": .bool(false)])] {
        let response = try await harness.post("/v1/session/\(root.rawValue)/archive", body)
        #expect(response.status == .conflict)
        #expect(try await response.text().contains("\(child.rawValue) (child)"))
        #expect(try await harness.store.record(root).lifecycle == .live)
        #expect(try await harness.store.record(child).lifecycle == .live)
      }
      #expect(try await harness.post("/v1/session/\(root.rawValue)/archive", .object(["force": .string("true")])).status == .badRequest)
      #expect(try await harness.post("/v1/session/\(root.rawValue)/archive", .object(["force": .bool(true)])).status == .ok)
      #expect(try await harness.store.record(root).lifecycle != .live)
      #expect(try await harness.store.record(child).lifecycle != .live)
    }
  }

  @Test func scriptForceArchivesAThreeLevelTreeAndClosesTheOutsideRequest() async throws {
    try await withSessionDeps {
      let entered = Gate()
      let release = Gate()
      let harness = try await SessionHarness(inference: { _, _ in
        entered.open()
        await release.wait()
        try Task.checkCancellation()
        return reply("done")
      })
      let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      let caller = try await harness.createSession(title: "owner")
      let root = try await harness.store.createSession(group: .shared, title: "coder", kind: .task, parent: caller, createdBy: caller.rawValue, executor: model)
      let child = try await harness.store.createSession(group: .shared, title: "proxy", kind: .task, parent: root, createdBy: root.rawValue, executor: model)
      let leaf = try await harness.store.createSession(group: .shared, title: "signup", kind: .task, parent: child, createdBy: child.rawValue, executor: model)
      let topLevel = try await harness.store.createSession(group: .shared, title: "independent", kind: .agent, createdBy: child.rawValue, executor: model)
      try await harness.store.markInterrupted(root)
      let delivery = try await harness.store.openRequest(on: root, from: caller, messageID: .init("script-request"), text: "work", deadline: nil)
      func script(_ options: String) async throws -> String {
        let result = try await callResult(harness, caller.rawValue, tool: "run_script", .object([
          "source": .string("import { archive } from \"wuhu:session\"; result(await archive(\"\(root.rawValue)\"\(options)).then(() => \"done\", e => e.message))"),
        ]))
        return resultText(result) ?? ""
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll(); release.open() }
        try await harness.deliver("start", to: leaf)
        await entered.wait()
        let refused = try await script("")
        #expect(refused.contains("\(leaf.rawValue) (signup)"))
        for id in [root, child, leaf] { #expect(try await harness.store.record(id).lifecycle == .live) }
        #expect(try await script(", { force: true }").contains("done"))
        for id in [root, child, leaf] {
          guard case .archived = try await harness.store.record(id).lifecycle else {
            Issue.record("\(id) remained live")
            continue
          }
        }
        #expect(try await harness.store.record(topLevel).lifecycle == .live)
        #expect(try await harness.store.record(caller).lifecycle == .live)
        let messages = try await harness.store.messages(conversation: delivery.message.conversation)
        let final = try #require(messages.first { $0.kind == .final })
        #expect(final.requestID == .init("script-request"))
        #expect(final.content.text.contains("archived before reporting"))
      }
    }
  }

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
