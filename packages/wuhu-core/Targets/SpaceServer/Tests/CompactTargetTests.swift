import Credentials
import Dependencies
import DeterministicDependencies
import ExecutionOwner
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import LoopCore
import class MainHub.Hub
import ModelProviders
import Scratch
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing
import WuhuAI

private let boundKeys = CredentialResolver.bound { provider in
  .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
}

private let summaryHead = GenerationHead(id: UUID(), timestamp: Date(), summary: "where things stand", snapshot: .init(preReads: ["/task.md"]), runningWork: [])

private func compactedTokens(_ id: SessionID) -> Int {
  summaryHead.lines(session: id).estimatedContextTokens(images: .claude)
}

private func directSession(_ harness: SessionHarness, owner: Hub, catalog: ProviderCatalog) async throws -> (SessionID, SessionModelRoute) {
  let created = try await harness.call("/v1/session", .object(["title": "Direct", "kind": "agent", "provider": "testing", "model": "test-model"]), as: SessionCreateOutput.self)
  let id = SessionID(created.id)
  let bound = SessionModelRoute(group: nil, member: nil, specifier: .init(provider: "testing", model: "test-model", effort: "high"), bindingFingerprint: catalog.document.providers["testing"]!.routeFingerprint, epoch: UUID().uuidString.lowercased(), reason: .create, placedAt: Date(), evidence: [])
  let route = try await owner.space.sessions.establishInferenceModelRoute(id, route: bound)
  try await harness.store.deliverMail(id)
  return (id, route)
}

@Suite(.deterministicDependencies) struct CompactTargetTests {
  @Test func aConcreteTargetTakesAGroupSessionOffItsGroupAndSurvivesRestart() async throws {
    try await withSessionDeps {
      let folder = try scratchURL("compact-target")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let file = folder.appending(path: "space.sqlite")
      let id: SessionID
      let old: SessionModelRoute
      let route: SessionModelRoute
      do {
        let space = try Space.open(file: file)
        _ = try await SessionToolFixture(space: space)
        let fs = await space.fs(.settings)
        var document = try ModelsDocument(json: Data(testModelsJSON.utf8))
        document.providers["alternate"] = document.providers["testing"]
        let groups = ["work": ModelsDocument.Group(members: [.init(id: "a", provider: "testing", model: "test-model"), .init(id: "b", provider: "alternate", model: "test-model")], defaultEffort: "high", policy: .quotaAware)]
        _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: nil)
        _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: nil)
        let catalog = try await groupCatalog(space: space, access: InferenceAccess(credentials: boundKeys))()
        let usage = UsageBoard()
        let placed = try #require(await modelRoutePreparer(catalog: { catalog }, usage: usage)(.modelGroup(id: "work", effort: "high"), .create))
        id = try await space.sessions.createSession(group: .shared, title: "Switch", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), snapshot: .init(), modelRoute: placed)
        old = try #require(await space.sessions.modelRoute(id))
        let tokens = compactedTokens(id)
        let prepare = compactionPlacement(store: space.sessions, catalog: { _ in catalog }, usage: usage)
        let transition = try #require(await prepare(id, tokens, .init(model: "alternate/test-model", effort: "low")))
        route = transition.route
        #expect(route.group == nil && route.member == nil)
        #expect(route.specifier == ModelSpecifier(provider: "alternate", model: "test-model", effort: "low"))
        #expect(route.reason == .compaction)
        #expect(transition.notice == "Model switched work:\(old.member!) → alternate/test-model (requested at compaction). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed.")
        #expect(transition.carriesTail)
        #expect(transition.binding?.epoch == route.epoch)
        _ = try await space.sessions.foldLines(id, head: summaryHead, transition: transition)
        try await space.close()
      }
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.record(id).executor == .kernel(route.specifier))
      #expect(try await reopened.sessions.modelRoute(id) == route)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [old, route])
      let lines = try await reopened.sessions.testLines(id)
      let expectedHead = summaryHead.lines(session: id)
      #expect(lines.prefix(expectedHead.count).map(\.message) == expectedHead.map(\.message))
      #expect(lines.last?.key == "subscription:model-route")
      try await reopened.close()
    }
  }

  @Test func aRefusedTargetLeavesRouteHistoryAndGenerationUntouched() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await GroupSwitchingTests().setup()
      let old = try #require(await owner.space.sessions.modelRoute(id))
      let generation = try await harness.store.generationState(id).generation
      let tokens = compactedTokens(id)
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
      let refusals: [(CompactionTarget, CatalogError)] = [
        (.init(model: "nope/x"), .unknownProvider("nope")),
        (.init(model: "testing/missing"), .unknownModel(provider: "testing", model: "missing")),
        (.init(model: "alternate/test-model", effort: "max"), .unknownEffort(provider: "alternate", model: "test-model", effort: "max")),
        (.init(model: "ghost"), .unknownGroup("ghost")),
        (.init(model: "work", effort: "max"), .groupMember(group: "work", member: "a", reason: .unknownEffort(provider: "testing", model: "test-model", effort: "max"))),
      ]
      for (target, refusal) in refusals {
        await #expect(throws: refusal) { try await prepare(id, tokens, target) }
      }
      var missing = catalog
      missing.credentials = .bound { provider in
        provider == "alternate" ? nil : .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let unready = missing
      let refusing = compactionPlacement(store: owner.space.sessions, catalog: { _ in unready }, usage: harness.runtime.usage)
      await #expect(throws: CatalogError.missingCredential(provider: "alternate")) { try await refusing(id, tokens, .init(model: "alternate/test-model")) }
      #expect(try await owner.space.sessions.modelRoute(id) == old)
      #expect(try await harness.store.modelRouteHistory(id) == [old])
      #expect(try await harness.store.generationState(id).generation == generation)
    }
  }

  @Test func aGroupIDRePlacesWithinItsGroupAndBringsADirectSessionIn() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await GroupSwitchingTests().setup()
      let old = try #require(await owner.space.sessions.modelRoute(id))
      try #require(old.member == "a")
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
      #expect(try await prepare(id, compactedTokens(id), .init(model: "work")) == nil)
      let reset = Date().timeIntervalSince1970 + 18000
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset), .init(name: "seven_day", usedPercent: 99, resetsAt: nil)], at: Date())
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: Date())
      let transition = try #require(await prepare(id, compactedTokens(id), .init(model: "work")))
      #expect(transition.route.group == "work" && transition.route.member == "b")
      #expect(transition.route.specifier.effort == old.specifier.effort)
      #expect(transition.notice?.hasPrefix("Model group work moved a → b (compaction).") == true)
      _ = try await harness.store.foldLines(id, head: summaryHead, transition: transition)
      #expect(try await owner.space.sessions.modelRoute(id) == transition.route)
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "work", effort: old.specifier.effort))

      let (direct, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let joining = try #require(await prepare(direct, compactedTokens(direct), .init(model: "work", effort: "low")))
      #expect(joining.route.group == "work" && joining.route.member == "b")
      #expect(joining.route.specifier == ModelSpecifier(provider: "alternate", model: "test-model", effort: "low"))
      #expect(joining.notice?.hasPrefix("Model switched testing/test-model → work:b (requested at compaction).") == true)
      _ = try await harness.store.foldLines(direct, head: summaryHead, transition: joining)
      #expect(try await harness.store.record(direct).executor == .modelGroup(id: "work", effort: "low"))
      #expect(try await harness.store.modelRouteHistory(direct) == [bound, joining.route])
    }
  }

  @Test func aSlashBearingGroupIDIsAGroupNotAProviderModel() async throws {
    try await withSessionDeps {
      let (harness, owner, _, _) = try await GroupSwitchingTests().setup()
      let fs = await harness.space.fs(.settings)
      let (entry, data) = try await fs.read(ModelsDocument.groupPath)
      var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
      groups["team/claude"] = groups["work"]
      _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
      let catalog = try await groupCatalog(space: harness.space, access: InferenceAccess(credentials: harness.credentials))()
      let (id, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
      let joining = try #require(await prepare(id, compactedTokens(id), .init(model: "team/claude")))
      #expect(joining.route.group == "team/claude" && joining.route.member != nil)
      #expect(joining.notice?.hasPrefix("Model switched testing/test-model → team/claude:") == true)
      _ = try await harness.store.foldLines(id, head: summaryHead, transition: joining)
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "team/claude", effort: joining.route.specifier.effort))
      #expect(try await harness.store.modelRouteHistory(id) == [bound, joining.route])
      #expect(try await prepare(id, compactedTokens(id), .init(model: "team/claude")) == nil)
    }
  }

  @Test func anEffortOnlyChangeKeepsTheEpochWithoutAReplayBoundary() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, _) = try await GroupSwitchingTests().setup()
      let (id, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let prepare = compactionPlacement(store: owner.space.sessions, catalog: { _ in catalog }, usage: harness.runtime.usage)
      let tokens = compactedTokens(id)
      #expect(try await prepare(id, tokens, .init(model: "testing/test-model")) == nil)
      let transition = try #require(await prepare(id, tokens, .init(model: "testing/test-model", effort: "low")))
      #expect(transition.route.epoch == bound.epoch)
      #expect(transition.route.specifier.effort == "low")
      #expect(transition.binding == nil)
      #expect(transition.notice == nil)
      #expect(transition.carriesTail)
      let committed = try await harness.store.foldLines(id, head: summaryHead, transition: transition)
      #expect(committed.map(\.message) == summaryHead.lines(session: id).map(\.message))
      #expect(try await harness.store.record(id).executor == .kernel(.init(provider: "testing", model: "test-model", effort: "low")))
      #expect(try await owner.space.sessions.modelRoute(id) == transition.route)
      #expect(try await harness.store.modelRouteHistory(id) == [bound])
    }
  }
}
