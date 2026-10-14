import Credentials
import Dependencies
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import SpaceContract
@testable import SpaceCore
@testable import SpaceServer
import Testing

@Suite struct ModelGroupRouteTests {
  func install(_ harness: SessionHarness) async throws {
    let fs = await harness.space.fs(.shared)
    let (entry, data) = try await fs.read("/models.json")
    var doc = try ModelsDocument(json: data)
    doc.providers["alternate"] = doc.providers["testing"]
    doc.groups["work"] = ModelsDocument.Group(members: [
      .init(id: "a", provider: "testing", model: "test-model"),
      .init(id: "b", provider: "alternate", model: "test-model"),
    ], defaultEffort: "high", policy: .quotaAware())
    _ = try await fs.write("/models.json", JSONEncoder().encode(doc), ifMatch: entry)
    _ = try await fs.write(ModelsDocument.groupPath, JSONEncoder().encode(doc.groups), ifMatch: nil)
  }

  @Test func createPinsByHeadroomAndStartOverReselectsAtomically() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(credentials: CredentialResolver { _ in .apiKey("fixture") })
      try await install(harness)
      @Dependency(\.date) var date
      let reset = date.now.timeIntervalSince1970 + 18000
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 90, resetsAt: reset)], at: date.now)
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 30, resetsAt: reset)], at: date.now)
      let created = try await harness.call("/v1/session", .object(["title": "Group", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
      let id = SessionID(created.id)
      let first = try #require(await harness.store.modelRoute(id))
      #expect(first.member == "b")
      #expect(first.reason == .create)
      #expect(created.provider == "alternate")
      #expect(created.modelGroup == "work")
      #expect(try await harness.store.record(id).executor == .modelGroup(id: "work", effort: "high"))
      harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset)], at: date.now)
      harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset)], at: date.now)
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
      let fs = await harness.space.fs(.shared)
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
