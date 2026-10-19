import Credentials
import Dependencies
import ExecutionOwner
import Foundation
import InferenceKit
import LoopCore
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

private func compacted(_ store: SessionStore, _ id: SessionID) async throws -> Transcript {
  try await store.transcript(id).compacted(head: summaryHead, kept: nil)
}

private func routeNotice(_ transcript: Transcript) -> String? {
  transcript.items.lazy.compactMap { item -> String? in
    guard case let .notification(notice) = item, notice.subscriptionID == SubscriptionID("model-route") else { return nil }
    return notice.content.text
  }.first
}

// A direct session after its first inference: bound to testing/test-model.
private func directSession(_ harness: SessionHarness, owner: Hub, catalog: ProviderCatalog) async throws -> (SessionID, SessionModelRoute) {
  let created = try await harness.call("/v1/session", .object(["title": "Direct", "kind": "agent", "provider": "testing", "model": "test-model"]), as: SessionCreateOutput.self)
  let id = SessionID(created.id)
  let bound = SessionModelRoute(group: nil, member: nil, specifier: .init(provider: "testing", model: "test-model", effort: "high"), bindingFingerprint: catalog.document.providers["testing"]!.routeFingerprint, epoch: UUID().uuidString.lowercased(), reason: .create, placedAt: Date(), evidence: [])
  return (id, try await owner.append(id, .modelRouteEstablished(bound)).value(SessionModelRoute.self))
}

@Suite struct CompactTargetTests {
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
        let fs = await space.fs(.shared)
        var document = try ModelsDocument(json: Data(testModelsJSON.utf8))
        document.providers["alternate"] = document.providers["testing"]
        let groups = ["work": ModelsDocument.Group(members: [.init(id: "a", provider: "testing", model: "test-model"), .init(id: "b", provider: "alternate", model: "test-model")], defaultEffort: "high", policy: .quotaAware())]
        _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: nil)
        _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: nil)
        let owner = Hub(space: space, credentials: boundKeys)
        let catalog = try await groupCatalog(owner: owner)()
        let usage = UsageBoard()
        let placed = try #require(await modelRoutePreparer(catalog: { catalog }, usage: usage)(.modelGroup(id: "work", effort: "high"), .create))
        id = try await space.sessions.createSession(group: .shared, title: "Switch", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), snapshot: .init(), modelRoute: placed)
        old = try #require(await owner.modelRoute(id))
        let transcript = try await compacted(space.sessions, id)
        let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: usage)
        let transition = try #require(await prepare(id, transcript, .init(model: "alternate/test-model", effort: "low")))
        route = transition.route
        #expect(route.group == nil && route.member == nil)
        #expect(route.specifier == ModelSpecifier(provider: "alternate", model: "test-model", effort: "low"))
        #expect(route.reason == .compaction)
        #expect(routeNotice(transition.transcript) == "Model switched work:\(old.member!) → alternate/test-model (requested at compaction). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed.")
        _ = try await owner.append(id, .compacted(closing: nil, head: summaryHead, kept: nil, completing: nil, transition: transition)).value(Transcript.self)
      }
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.record(id).executor == .kernel(route.specifier))
      #expect(try await reopened.sessions.modelRoute(id) == route)
      #expect(try await reopened.sessions.modelRouteHistory(id) == [old, route])
      let transcript = try await reopened.sessions.transcript(id)
      #expect(transcript.replayBinding?.epoch == route.epoch)
      guard case let .generationHead(head)? = transcript.items.first else { Issue.record("missing head"); return }
      #expect(head.summary == summaryHead.summary)
      #expect(head.snapshot.preReads == ["/task.md"])
    }
  }

  @Test func aRefusedTargetLeavesRouteHistoryAndGenerationUntouched() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await GroupSwitchingTests().setup()
      let old = try #require(await owner.modelRoute(id))
      let generation = try await harness.store.generationState(id).generation
      let transcript = try await compacted(harness.store, id)
      let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
      let refusals: [(CompactionTarget, CatalogError)] = [
        (.init(model: "nope/x"), .unknownProvider("nope")),
        (.init(model: "testing/missing"), .unknownModel(provider: "testing", model: "missing")),
        (.init(model: "alternate/test-model", effort: "max"), .unknownEffort(provider: "alternate", model: "test-model", effort: "max")),
        (.init(model: "ghost"), .unknownGroup("ghost")),
        (.init(model: "work", effort: "max"), .groupMember(group: "work", member: "a", reason: .unknownEffort(provider: "testing", model: "test-model", effort: "max"))),
      ]
      for (target, refusal) in refusals {
        await #expect(throws: refusal) { try await prepare(id, transcript, target) }
      }
      var missing = catalog
      missing.credentials = .bound { provider in
        provider == "alternate" ? nil : .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
      }
      let unready = missing
      let refusing = compactionPlacement(owner: owner, catalog: { unready }, usage: harness.runtime.usage)
      await #expect(throws: CatalogError.missingCredential(provider: "alternate")) { try await refusing(id, transcript, .init(model: "alternate/test-model")) }
      #expect(try await owner.modelRoute(id) == old)
      #expect(try await harness.store.modelRouteHistory(id) == [old])
      #expect(try await harness.store.generationState(id).generation == generation)
    }
  }

  @Test func aGroupIDRePlacesWithinItsGroupAndBringsADirectSessionIn() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, id) = try await GroupSwitchingTests().setup()
      let old = try #require(await owner.modelRoute(id))
      try #require(old.member == "a")
      let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
      #expect(try await prepare(id, compacted(harness.store, id), .init(model: "work")) == nil)
      let reset = Date().timeIntervalSince1970 + 18000
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset)], at: Date())
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset)], at: Date())
      let transition = try #require(await prepare(id, compacted(harness.store, id), .init(model: "work")))
      #expect(transition.route.group == "work" && transition.route.member == "b")
      #expect(transition.route.specifier.effort == old.specifier.effort)
      #expect(routeNotice(transition.transcript)?.hasPrefix("Model group work moved a → b (compaction).") == true)
      _ = try await owner.append(id, .compacted(closing: nil, head: summaryHead, kept: nil, completing: nil, transition: transition)).value(Transcript.self)
      #expect(try await owner.modelRoute(id) == transition.route)
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "work", effort: old.specifier.effort))

      let (direct, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let joining = try #require(await prepare(direct, compacted(harness.store, direct), .init(model: "work", effort: "low")))
      #expect(joining.route.group == "work" && joining.route.member == "b")
      #expect(joining.route.specifier == ModelSpecifier(provider: "alternate", model: "test-model", effort: "low"))
      #expect(routeNotice(joining.transcript)?.hasPrefix("Model switched testing/test-model → work:b (requested at compaction).") == true)
      _ = try await owner.append(direct, .compacted(closing: nil, head: summaryHead, kept: nil, completing: nil, transition: joining)).value(Transcript.self)
      #expect(try await harness.store.record(direct).executor == .modelGroup(id: "work", effort: "low"))
      #expect(try await harness.store.modelRouteHistory(direct) == [bound, joining.route])
    }
  }

  @Test func aSlashBearingGroupIDIsAGroupNotAProviderModel() async throws {
    try await withSessionDeps {
      let (harness, owner, _, _) = try await GroupSwitchingTests().setup()
      let fs = await harness.space.fs(.shared)
      let (entry, data) = try await fs.read(ModelsDocument.groupPath)
      var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: data)
      groups["team/claude"] = groups["work"]
      _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: entry)
      let catalog = try await groupCatalog(owner: owner)()
      let (id, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
      let joining = try #require(await prepare(id, compacted(harness.store, id), .init(model: "team/claude")))
      #expect(joining.route.group == "team/claude" && joining.route.member != nil)
      #expect(routeNotice(joining.transcript)?.hasPrefix("Model switched testing/test-model → team/claude:") == true)
      _ = try await owner.append(id, .compacted(closing: nil, head: summaryHead, kept: nil, completing: nil, transition: joining)).value(Transcript.self)
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "team/claude", effort: joining.route.specifier.effort))
      #expect(try await harness.store.modelRouteHistory(id) == [bound, joining.route])
      #expect(try await prepare(id, compacted(harness.store, id), .init(model: "team/claude")) == nil)
    }
  }

  @Test func anEffortOnlyChangeKeepsTheEpochAndTheTranscript() async throws {
    try await withSessionDeps {
      let (harness, owner, catalog, _) = try await GroupSwitchingTests().setup()
      let (id, bound) = try await directSession(harness, owner: owner, catalog: catalog)
      let prepare = compactionPlacement(owner: owner, catalog: { catalog }, usage: harness.runtime.usage)
      let transcript = try await compacted(harness.store, id)
      #expect(try await prepare(id, transcript, .init(model: "testing/test-model")) == nil)
      let transition = try #require(await prepare(id, transcript, .init(model: "testing/test-model", effort: "low")))
      #expect(transition.route.epoch == bound.epoch)
      #expect(transition.route.specifier.effort == "low")
      #expect(transition.transcript == transcript)
      _ = try await owner.append(id, .compacted(closing: nil, head: summaryHead, kept: nil, completing: nil, transition: transition)).value(Transcript.self)
      #expect(try await harness.store.record(id).executor == .kernel(.init(provider: "testing", model: "test-model", effort: "low")))
      #expect(try await owner.modelRoute(id) == transition.route)
      #expect(try await harness.store.modelRouteHistory(id) == [bound])
    }
  }
}
