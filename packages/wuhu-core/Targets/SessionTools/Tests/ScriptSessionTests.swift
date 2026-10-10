import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
@_spi(Testing) import SpaceCore
import Testing

struct ScriptSessionTests {
  @Test func scriptsRejectRemovedExecutorWithoutCallingModelResolver() async throws {
    try await withRig(resolveModelExecutor: { _, _, _ in
      Issue.record("removed executor must not resolve a kernel model")
      throw ExecutorUnavailableError()
    }) { rig in
      let outcome = try await rig.evaluate("""
      import { createSession } from "wuhu:session"
      try {
        await createSession({title:"removed", executor:"claude-code"})
        result({created:true})
      } catch (error) {
        result({created:false, message:error.message, code:error.code})
      }
      """)
      #expect(outcome.object?["created"] == false)
      #expect(outcome.object?["message"] == "executor no longer supported")
      #expect(outcome.object?["code"] == "executorNoLongerSupported")
    }
  }

  @Test func scriptsCreateSessionsAndActOnlyOnTheirOwnTree() async throws {
    let space = try Space.inMemory()
    let verbs = Box<[String]>([])
    let control = SessionControl { verb, id, _ in
      let title = try await space.sessions.record(id).title
      verbs.withLock { $0.append("\(verb.rawValue) \(title)") }
    }
    try await withRig(
      space: { space },
      resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      },
      control: control,
      prepare: { space, _ in _ = try await makeSession(space, name: "stranger") },
    ) { rig in
      try await rig.run("sessions")
      rig.probe("verbs: \(verbs.value)")
      rig.probe("tags: \(try await rig.space.sessions.record(rig.session).tags)")
      try rig.expect("sessions")
    }
  }

  @Test func anArchivedSessionsScriptIsRefused() async throws {
    let space = try Space.inMemory()
    try await withRig(
      space: { space },
      resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      },
      control: SessionControl { _, _, _ in },
      prepare: { space, session in _ = try await space.sessions.archive(session, grace: .seconds(3600)) },
    ) { rig in
      try await rig.run("sessions-archived")
      try rig.expect("sessions-archived")
    }
  }

  // Finding: a keyed retry after a failed clone must not answer with a
  // half-made session. It fails the same way until the clone can succeed,
  // then clones, opens the request once and returns the first session.
  @Test func aKeyedRetryFinishesASessionWhoseCloneFailed() async throws {
    let space = try Space.inMemory()
    try await withRig(
      space: { space },
      resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      },
      prepare: { space, _ in
        _ = try await space.fs(.shared).write("/templates/coder/template.json", Data(#"{"kind":"task"}"#.utf8), ifMatch: nil)
        _ = try await space.fs(.shared).write("/templates/coder/AGENTS.md", Data("write code".utf8), ifMatch: nil)
        await space.failTemplateClones("the disk is full")
      },
    ) { rig in
      try await rig.run("sessions-clone")
      try await rig.run("sessions-clone")
      let receipt = try #require(try await space.sessions.receipt(rig.session, toolCallID: ToolCallID("script-key:coder")))
      guard case let .createSession(first) = receipt else { throw Mismatch("expected a create receipt, got \(receipt)") }
      let home = SessionHome.path(of: first.sessionID) + "/AGENTS.md"
      let cloned = (try? await space.fs(.shared).read(home)) != nil
      rig.probe("owed: \(first.cloneOwed == true), home: \(cloned)")

      await space.failTemplateClones(nil)
      try await rig.run("sessions-clone")
      guard case let .createSession(settled)? = try await space.sessions.receipt(
        rig.session, toolCallID: ToolCallID("script-key:coder"),
      ) else { throw Mismatch("the receipt is gone") }
      let clone = String(decoding: try await space.fs(.shared).read(home).1, as: UTF8.self)
      rig.probe("owed: \(settled.cloneOwed == true), home: \(clone)")

      // Settled: a further replay leaves the session's own edits alone.
      _ = try await space.fs(.shared).write(home, Data("my own notes".utf8), ifMatch: nil)
      try await rig.run("sessions-clone")
      var briefs = 0
      for conversation in try await space.sessions.conversations(member: first.sessionID.rawValue)
        where conversation.kind == .dmSession
      {
        briefs += try await space.sessions.messages(conversation: conversation.id).count
      }
      let kept = String(decoding: try await space.fs(.shared).read(home).1, as: UTF8.self)
      rig.probe("home: \(kept), briefs: \(briefs)")
      try rig.expect("sessions-clone")
    }
  }
}
