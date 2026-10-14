#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.CatalogError
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

func testModelGroupRoute(_ executor: SessionExecutor, reason: ModelPlacementReason = .create) -> SessionModelRoute? {
  guard case let .modelGroup(id, effort) = executor else { return nil }
  return SessionModelRoute(
    group: id, member: "initial", specifier: .init(provider: "pinned-provider", model: "pinned-model", effort: effort),
    bindingFingerprint: "binding", epoch: "epoch", reason: reason, placedAt: Date(timeIntervalSince1970: 1), evidence: [],
  )
}

@Suite struct ModelGroupToolTests {
  @Test func childrenInheritRequestedGroupAndExplicitTargetsReplaceTemplates() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let parent = try await space.sessions.createSession(
        group: .shared, title: "group parent", kind: .agent, createdBy: "owner",
        executor: .modelGroup(id: "work", effort: "high"),
        modelRoute: testModelGroupRoute(.modelGroup(id: "work", effort: "high")),
      )
      let targets = Box<[String]>([])
      let tools = ToolExecutor(
        space: space,
        resolveModelExecutor: { provider, model, effort in
          targets.withLock { $0.append("\(provider)/\(model)") }
          return .kernel(.init(provider: provider, model: model, effort: effort ?? "low"))
        },
        resolveModelGroup: { id, effort in
          targets.withLock { $0.append(id) }
          return .modelGroup(id: id, effort: effort ?? "low")
        },
        prepareModelRoute: { executor, reason in testModelGroupRoute(executor, reason: reason) },
      )
      _ = try await space.fs(.shared).write("/templates/concrete/template.json", Data(#"{"provider":"p","model":"m","effort":"low"}"#.utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/templates/group/template.json", Data(#"{"modelGroup":"template-group","effort":"low"}"#.utf8), ifMatch: nil)
      var world = ToolWorld(executor: tools, session: parent)
      for (arguments, expected): (JSONValue, SessionExecutor) in [
        (["title": "inherited"], .modelGroup(id: "work", effort: "high")),
        (["title": "explicit group", "template": "concrete", "modelGroup": "other", "effort": "high"], .modelGroup(id: "other", effort: "high")),
        (["title": "explicit concrete", "template": "group", "provider": "q", "model": "n", "effort": "high"], .kernel(.init(provider: "q", model: "n", effort: "high"))),
      ] {
        guard case let .createSession(result) = try await world.run("create_session", .object(arguments.object!)) else {
          Issue.record("expected created session"); continue
        }
        #expect(try await space.sessions.record(result.sessionID).executor == expected)
      }
      #expect(targets.value == ["work", "other", "q/n"])
      guard case .failure = try await world.run("create_session", .object(["title": "mixed", "provider": "p", "modelGroup": "work"])) else {
        Issue.record("mixed target should fail"); return
      }
      #expect(targets.value == ["work", "other", "q/n"])
    }
  }

  @Test func groupCreationStoresPreparedRouteAndReplayDoesNotResolveOrPlaceAgain() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let parent = try await makeSession(space)
      let placements = Box<[ModelPlacementReason]>([])
      let resolutions = Box(0)
      let route = SessionModelRoute(
        group: "work", member: "first", specifier: .init(provider: "p", model: "m", effort: "high"),
        bindingFingerprint: "binding", epoch: "epoch", reason: .create, placedAt: Date(timeIntervalSince1970: 1), evidence: [],
      )
      let owner = InProcessToolOwnerClient(
        space: space,
        resolveModelExecutor: { _, _, _ in throw ExecutorSpecError("unexpected concrete target") },
        resolveModelGroup: { id, _ in
          let count = resolutions.withLock { $0 += 1; return $0 }
          guard count == 1 else { throw CatalogError.unknownGroup(id) }
          return .modelGroup(id: id, effort: "high")
        },
        prepareModelRoute: { _, reason in placements.withLock { $0.append(reason) }; return route },
      )
      let tools = ToolExecutor(owner: owner)
      var world = ToolWorld(executor: tools, session: parent)
      guard case let .createSession(first) = try await world.run("create_session", .object(["title": "routed", "modelGroup": "work"]), id: "create-routed") else {
        Issue.record("expected created session"); return
      }
      #expect(first.modelGroup == "work")
      #expect(first.member == "first")
      #expect(first.provider == "p" && first.model == "m")
      #expect(try await space.sessions.modelRoute(first.sessionID) == route)
      guard case let .createSession(replayed) = try await world.run("create_session", .object(["title": "routed", "modelGroup": "work"]), id: "create-routed") else {
        Issue.record("expected replayed session"); return
      }
      #expect(first.sessionID == replayed.sessionID)
      #expect(placements.value == [.create])
      #expect(resolutions.value == 1)
    }
  }

  @Test func groupCatalogFailuresRetainMachineReadableCodes() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let tools = ToolExecutor(
        space: space,
        resolveModelExecutor: { _, _, _ in throw ExecutorSpecError("unexpected concrete target") },
        resolveModelGroup: { id, _ in throw CatalogError.unknownGroup(id) },
      )
      var world = ToolWorld(executor: tools, session: try await makeSession(space))
      guard case let .failure(error) = try await world.run("create_session", .object(["title": "bad group", "modelGroup": "absent"])) else {
        Issue.record("expected group failure"); return
      }
      #expect(error.code == "modelGroupConfiguration")
    }
  }

  @Test func invalidStoredGroupBindingRetainsMachineReadableCode() throws {
    let owner = InProcessToolOwnerClient(space: try Space.inMemory())
    let failure = owner.problem(.modelRouteInvalid(group: "work", member: "initial"))
    #expect(failure.code == "modelRouteInvalid")
    #expect(failure.message.contains("work") && failure.message.contains("initial"))
  }

  @Test func templateDiscoveryIncludesGroupIntent() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/templates/group/template.json", Data(#"{"modelGroup":"work","effort":"high"}"#.utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))
      guard case let .templates(result) = try await world.run("templates", .object([:])) else {
        Issue.record("expected templates"); return
      }
      let group = try #require(result.templates.first)
      #expect(group.modelGroup == "work")
      #expect(group.provider == nil && group.model == nil)
    }
  }
}
