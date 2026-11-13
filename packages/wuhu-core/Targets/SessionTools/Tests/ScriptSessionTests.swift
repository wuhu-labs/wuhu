import DeterministicDependencies
import LoopCore
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import enum ModelProviders.CatalogError
import SessionDomain
@testable import SessionTools
@testable @_spi(Testing) import SpaceCore
import Testing

@Suite(.deterministicDependencies)
struct ScriptSessionTests {
  @Test func scriptsCreateWithRequestedGroupInsteadOfAnInheritedConcreteModel() async throws {
    let calls = Box<[String]>([])
    try await withRig(
      resolveModelExecutor: { _, _, _ in
        Issue.record("group request must not resolve an inherited concrete model")
        throw ExecutorSpecError("unexpected concrete target")
      },
      resolveModelGroup: { id, effort in
        calls.withLock { $0.append(id) }
        return .modelGroup(id: id, effort: effort ?? "high")
      },
      prepareModelRoute: { executor, reason in testModelGroupRoute(executor, reason: reason) },
    ) { rig in
      let result = try await rig.evaluate(#"import {createSession} from 'wuhu:session'; result(await createSession({title:'group child',modelGroup:'work'}))"#)
      let id = try #require(result.object?["id"]?.stringValue)
      #expect(try await rig.space.sessions.record(SessionID(id)).executor == .modelGroup(id: "work", effort: "high"))
      #expect(calls.value == ["work"])
      #expect(result.object?["modelGroup"] == "work")
      #expect(result.object?["member"] == "initial")
      #expect(result.object?["provider"] == "pinned-provider")
      let rawConfig = try await rig.evaluate("""
      import {query} from 'wuhu:space'
      const id = \(JSONValue.string(id).jsonString())
      result(JSON.parse((await query`SELECT executor_config FROM sessions WHERE id = ${id}`)[0].executor_config))
      """)
      #expect(rawConfig == .object(["provider": "pinned-provider", "model": "pinned-model", "effort": "high"]))
    }
  }

  @Test func scriptCreationRetainsGroupCatalogErrorCode() async throws {
    try await withRig(
      resolveModelExecutor: { _, _, _ in throw ExecutorSpecError("unexpected concrete target") },
      resolveModelGroup: { id, _ in throw CatalogError.unknownGroup(id) },
    ) { rig in
      let result = try await rig.evaluate(#"import {createSession} from 'wuhu:session'; try {await createSession({title:'bad group',modelGroup:'absent'})}catch(e){result(e.code)}"#)
      #expect(result == .string("modelGroupConfiguration"))
    }
  }

  @Test func scriptsRejectAnUnknownExecutorWithoutCallingModelResolver() async throws {
    try await withRig(resolveModelExecutor: { _, _, _ in
      Issue.record("an unknown executor must not resolve a kernel model")
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
      #expect(outcome.object?["message"] == "createSession: unknown executor: claude-code")
      #expect(outcome.object?["code"] == "invalidArgument")
    }
  }

  @Test func scriptsCreateSessionsAndActOnlyOnTheirOwnTree() async throws {
    let space = try Space.inMemory()
    try await withRig(
      space: { space },
      resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      },
      prepare: { space, _ in _ = try await makeSession(space, name: "stranger") },
    ) { rig in
      try await rig.run("sessions")
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
      prepare: { space, session in _ = try await space.sessions.archive(session, grace: .seconds(3600)) },
    ) { rig in
      let failure = Box<String?>(nil)
      try await rig.command("result(1)") {
        if case let .failure(text) = $0 { failure.withLock { $0 = text } }
      }
      #expect(failure.value?.contains("is archived and may no longer act") == true)
    }
  }

  @Test func aCreateWhoseCloneFailedThrowsTheNewSessionsID() async throws {
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
      try rig.expect("sessions-clone")
    }
  }
}
