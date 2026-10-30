import Credentials
import Dependencies
import DeterministicDependencies
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct ModelGroupRouteTests {
  func install(_ harness: SessionHarness, model: String = "test-model") async throws {
    let fs = await harness.space.fs(.settings)
    let (entry, data) = try await fs.read("/models.json")
    var doc = try ModelsDocument(json: data)
    if model != "test-model", let entry = doc.providers["testing"]?.models.removeValue(forKey: "test-model") {
      doc.providers["testing"]?.models[model] = entry
    }
    doc.providers["alternate"] = doc.providers["testing"]
    doc.groups["work"] = ModelsDocument.Group(members: [
      .init(id: "a", provider: "testing", model: model),
      .init(id: "b", provider: "alternate", model: model),
    ], defaultEffort: "high", policy: .quotaAware)
    _ = try await fs.write("/models.json", JSONEncoder().encode(doc), ifMatch: entry)
    _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(doc.groups), ifMatch: nil)
  }

  @Test func createPinsByHeadroomAndStartOverReselectsAtomically() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { _ in .apiKey("fixture") })
      try await install(harness)
      @Dependency(\.date) var date
      let reset = date.now.timeIntervalSince1970 + 18000
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 90, resetsAt: reset), .init(name: "seven_day", usedPercent: 90, resetsAt: nil)], at: date.now)
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 30, resetsAt: reset), .init(name: "seven_day", usedPercent: 30, resetsAt: nil)], at: date.now)
      let created = try await harness.call("/v1/session", .object(["title": "Group", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let id = SessionID(created.id)
      let first = try #require(await harness.store.modelRoute(id))
      #expect(first.member == "b")
      #expect(first.reason == .create)
      #expect(created.provider == "alternate")
      #expect(created.modelGroup == "work")
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: date.now)
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset), .init(name: "seven_day", usedPercent: 99, resetsAt: nil)], at: date.now)
      #expect(try await harness.store.modelRoute(id) == first)
      let response = try await harness.get("/v1/session/\(id.rawValue)/model-route")
      let inspected = try await response.body.json(SessionModelRouteOutput.self)
      #expect(inspected.activeProvider == "alternate")
      #expect(inspected.requestedTarget.object?["modelGroup"] == "work")
      let restarted = try await harness.call("/v1/session/\(id.rawValue)/restart", .null, as: SessionRestartOutput.self)
      #expect(restarted.provider == "testing")
      let second = try #require(await harness.store.modelRoute(id))
      #expect(second.member == "a")
      #expect(second.reason == .startOver)
      #expect(second.epoch != first.epoch)
      #expect(restarted.generation == 1)
      let rows = try await harness.space.query("SELECT member_id, provider FROM session_model_routes", as: .shared(.anonymous))
      #expect(rows.rows.count == 1)
    }
  }

  @Test func namedWindowsReachPlacementEvidenceWithoutChangingOtherModels() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { _ in .apiKey("fixture") })
      try await install(harness)
      let fs = await harness.space.fs(.settings)
      let (token, data) = try await fs.read("/models.json")
      var doc = try ModelsDocument(json: data)
      for provider in ["testing", "alternate"] {
        doc.providers[provider]!.models["limited"] = doc.providers[provider]!.models["test-model"]
        doc.providers[provider]!.models["limited"]!.usageWindows = ["five_hour", "seven_day", "model_week"]
      }
      _ = try await fs.write("/models.json", JSONEncoder().encode(doc), ifMatch: token)
      let (groupsToken, groupsData) = try await fs.read(ModelsDocument.groupPath)
      var groups = try JSONDecoder().decode([String: ModelsDocument.Group].self, from: groupsData)
      groups["limited"] = groups["work"]
      for index in groups["limited"]!.members.indices { groups["limited"]!.members[index].model = "limited" }
      _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(groups), ifMatch: groupsToken)
      @Dependency(\.date) var date
      let reset = date.now.timeIntervalSince1970 + 604_800
      for (provider, used) in [("testing", 100), ("alternate", 50)] {
        let event: JSONValue = .object(["rate_limits": .object(["windows": .object([
          "five_hour": .object(["used_percent": .number(provider == "testing" ? 10 : 50), "window_minutes": 300, "reset_at": .number(reset)]),
          "seven_day": .object(["used_percent": 10, "window_minutes": 10080, "reset_at": .number(reset)]),
          "model_week": .object(["used_percent": .number(Double(used)), "window_minutes": 10080, "reset_at": .number(reset)]),
        ])])])
        let parsed = codexSocketUsage(event)
        harness.runtime.usage.record(provider, plan: parsed.plan, windows: parsed.windows, at: date.now)
      }
      let limited = try await harness.call("/v1/session", .object(["title": "Limited", "kind": "agent", "modelGroup": "limited"]), as: SessionCreateOutput.self)
      #expect(limited.provider == "alternate")
      let route = try #require(await harness.store.modelRoute(SessionID(limited.id)))
      #expect(route.evidence.count == 2)
      #expect(route.evidence.allSatisfy { $0.windows.map(\.name) == ["five_hour", "seven_day", "model_week"] })
      let regular = try await harness.call("/v1/session", .object(["title": "Regular", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      #expect(regular.provider == "testing")
    }
  }

  @Test func invalidAlternateAndEmptyRuntimePlacementFailBeforeCreation() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { id in id == "testing" ? .apiKey("fixture") : nil })
      try await install(harness)
      let response = try await harness.post("/v1/session", .object(["title": "Group", "kind": "agent", "modelGroup": "work"]))
      #expect(response.status.code == 422)
      let body = try await response.text()
      #expect(body.contains("member b"))
      #expect(try await harness.space.query("SELECT id FROM sessions", as: .shared(.anonymous)).rows.isEmpty)
    }
  }

  @Test func discoveryListsOrderedMembersAndSelectPolicy() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { _ in .apiKey("fixture") })
      try await install(harness)
      let response = try await harness.get("/v1/providers")
      let discovered = try await response.body.json(ProvidersOutput.self)
      let group = try #require(discovered.groups?.first)
      #expect(group.id == "work")
      #expect(group.members.map(\.id) == ["a", "b"])
      #expect(group.defaultEffort == "high")
      #expect(group.effortLevels == ["high", "low"])
      #expect(group.policy.object?["type"] == "quotaAware")
    }
  }
}

extension ModelGroupRouteTests {
  @Test func explicitConcreteStartOverCanRecoverFromMalformedGroupDeclaration() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { _ in .apiKey("fixture") })
      try await install(harness)
      let created = try await harness.call("/v1/session", .object(["title": "Group", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let fs = await harness.space.fs(.settings)
      let (token, _) = try await fs.read(ModelsDocument.groupPath)
      _ = try await fs.write(ModelsDocument.groupPath, Data(#"{"work":{"kind":"group","members":[],"defaultEffort":"high"}}"#.utf8), ifMatch: token)
      let restarted = try await harness.call("/v1/session/\(created.id)/restart", .object(["provider": "testing", "model": "test-model"]), as: SessionRestartOutput.self)
      #expect(restarted.provider == "testing")
      #expect(restarted.modelGroup == nil)
      #expect(await harness.runtime.budget(SessionID(created.id)).usableTokens == 99000)
      #expect(try await harness.store.modelRoute(SessionID(created.id)) == nil)
      #expect(try await harness.store.modelRouteHistory(SessionID(created.id)).count == 1)
    }
  }
}

extension ModelGroupRouteTests {
  @Test func catalogErrorsDoNotPreventSettingsWritesDiscoveryOrHealthySessions() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: .init { _ in .apiKey("fixture") })
      try await install(harness)
      let fs = await harness.space.fs(.settings)
      let (token, data) = try await fs.read(ModelsDocument.spacePath)
      var document = try ModelsDocument(json: data)
      document.providers["alternate"]!.capacity = ["weekly": 2]
      _ = try await fs.write(ModelsDocument.spacePath, JSONEncoder().encode(document), ifMatch: token)
      let (groupsToken, _) = try await fs.read(ModelsDocument.groupPath)
      let groups = #"{"good":{"kind":"group","members":[{"id":"a","provider":"testing","model":"test-model"},{"id":"b","provider":"alternate","model":"test-model"}],"defaultEffort":"high"},"bad":{"kind":"group","members":[{"id":"b","provider":"alternate","model":"test-model"}],"defaultEffort":"high"},"malformed":{"kind":"group","policy":{"type":"unknown"}}}"#
      _ = try await fs.write(ModelsDocument.groupPath, Data(groups.utf8), ifMatch: groupsToken)
      let response = try await harness.get("/v1/providers")
      #expect(response.status.code == 200)
      let output = try await response.body.json(ProvidersOutput.self)
      #expect(output.providers.map(\.id) == ["alternate", "testing"])
      #expect(output.providerErrors?.first(where: { $0.id == "alternate" })?.message == CatalogError.invalidCapacity(provider: "alternate", window: "weekly").description)
      #expect(output.groups?.map(\.id) == ["good"])
      #expect(output.groups?.first?.memberErrors?.map(\.id) == ["b"])
      #expect(output.groupErrors?.map(\.id) == ["bad", "malformed"])
      let concrete = try await harness.call("/v1/session", .object(["title": "Healthy", "kind": "agent", "provider": "testing", "model": "test-model"]), as: SessionCreateOutput.self)
      #expect(concrete.provider == "testing")
      let group = try await harness.call("/v1/session", .object(["title": "Healthy group", "kind": "agent", "modelGroup": "good"]), as: SessionCreateOutput.self)
      #expect(group.modelGroup == "good")
      #expect(group.provider == "testing")
      let restarted = try await harness.call("/v1/session/\(group.id)/restart", .null, as: SessionRestartOutput.self)
      #expect(restarted.provider == "testing")
      let held = try #require(await harness.store.modelRoute(SessionID(group.id)))
      let catalog = ProviderCatalog(document: try await readModelsDocument(space: harness.space), credentials: .unavailable)
      let replacement = try replacementRoute(held, catalog: catalog, usage: harness.runtime.usage, reason: .compaction)
      #expect(replacement.specifier.provider == "testing")
      let bad = try await harness.post("/v1/session", .object(["title": "Bad", "kind": "agent", "modelGroup": "bad"]))
      #expect(bad.status.code == 422)
      #expect(try await bad.text().contains("invalid capacity"))
    }
  }
}
