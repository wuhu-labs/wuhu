import Credentials
import Foundation
import InferenceKit
import SessionDomain
import Testing

private func groupDocument(policy: ModelsDocument.Policy = .quotaAware()) throws -> ModelsDocument {
  var document = try ModelsDocument(json: fixtureJSON)
  document.groups["work"] = ModelsDocument.Group(members: [
    .init(id: "primary", provider: "anthropic", model: "claude-sonnet-5"),
    .init(id: "secondary", provider: "openai", model: "gpt-5.4"),
  ], defaultEffort: "high", policy: policy)
  return document
}

@Suite struct ModelGroupTests {
  @Test func unionRoundTripsAndPolicyDefaults() throws {
    let document = try groupDocument()
    #expect(try ModelsDocument(json: JSONEncoder().encode(document), groupsJSON: JSONEncoder().encode(document.groups)) == document)
    let text = #"{"work":{"kind":"group","members":[{"id":"a","provider":"anthropic","model":"claude-sonnet-5"}],"defaultEffort":"high"}}"#
    #expect(try ModelsDocument(json: fixtureJSON, groupsJSON: Data(text.utf8)).groups["work"]?.policy == .quotaAware())
  }

  @Test(arguments: [
    #"{"type":"url-test"}"#,
    #"{"type":"fallback"}"#,
    #"{"type":"select","member":"primary","extra":1}"#,
    #"{"type":"quotaAware","holdDownSeconds":-1}"#,
    #"{"type":"quotaAware","holdDownSeconds":86401}"#,
    #"{"type":"quotaAware","holdDownSeconds":0.5}"#,
  ]) func invalidPoliciesAreTyped(_ policy: String) throws {
    let json = #"{"work":{"kind":"group","members":[],"defaultEffort":"high","policy":POLICY}}"#.replacingOccurrences(of: "POLICY", with: policy)
    #expect(throws: CatalogError.self) { try ModelsDocument(json: fixtureJSON, groupsJSON: Data(json.utf8)) }
  }

  @Test func allMembersAndDefaultEffortAreValidated() async throws {
    let doc = try groupDocument(policy: .select(member: "primary"))
    let catalog = ProviderCatalog(document: doc, credentials: CredentialResolver { provider in
      provider == "anthropic" ? .apiKey("fixture") : nil
    })
    await #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .missingCredential(provider: "openai"))) {
      try await catalog.validateGroupReadiness("work")
    }
    #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .unknownEffort(provider: "openai", model: "gpt-5.4", effort: "max"))) {
      try catalog.validateGroup("work", effort: "max")
    }
    var bad = doc
    bad.groups["work"]!.defaultEffort = "max"
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: bad, credentials: .unavailable).validateGroup("work", effort: "high") }
  }

  @Test func duplicatesNestingAndInvalidBudgetFail() throws {
    var doc = try groupDocument()
    doc.groups["work"]!.members[1].id = "primary"
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: doc, credentials: .unavailable).validateGroup("work") }
    doc = try groupDocument()
    doc.groups["work"]!.members[1].provider = "work"
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: doc, credentials: .unavailable).validateGroup("work") }
    doc = try groupDocument()
    doc.providers["openai"]!.models["gpt-5.4"]!.maxOutput = 400_000
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: doc, credentials: .unavailable).validateGroup("work") }
  }

  @Test func pinSurvivesReorderAndSelectEditButNotRemovalOrRebinding() throws {
    var doc = try groupDocument()
    let route = SessionModelRoute(group: "work", member: "primary", specifier: .init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"), bindingFingerprint: doc.providers["anthropic"]!.routeFingerprint, epoch: "1", reason: .create, placedAt: Date(), evidence: [])
    doc.groups["work"]!.members.reverse()
    doc.groups["work"]!.policy = .select(member: "secondary")
    #expect(try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") == route.specifier)
    doc.groups["work"]!.members.removeAll { $0.id == "primary" }
    #expect(throws: CatalogError.modelRouteInvalid(group: "work", member: "primary")) { try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") }
    doc = try groupDocument()
    doc.groups["work"]!.members[0].provider = "deepseek"
    doc.groups["work"]!.members[0].model = "deepseek-v4-pro"
    #expect(throws: CatalogError.modelRouteInvalid(group: "work", member: "primary")) { try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") }
    doc = try groupDocument()
    doc.providers["anthropic"]!.capacity = ["fiveHour": 4]
    #expect(try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") == route.specifier)
    doc.providers["anthropic"]!.baseURL = URL(string: "https://other.example/v1")!
    #expect(throws: CatalogError.modelRouteInvalid(group: "work", member: "primary")) { try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") }
  }

  @Test func capacityHintsAreValidatedAndConcreteOperationsRefuseGroups() throws {
    var doc = try groupDocument()
    let spec = ModelSpecifier(provider: "work", model: "ignored", effort: "high")
    #expect(throws: CatalogError.unsupportedTarget("work")) { try ProviderCatalog(document: doc, credentials: .unavailable).validate(spec) }
    for hint: [String: Double] in [["fiveHour": 0], ["sevenDay": -1], ["weekly": 2]] {
      doc.providers["openai"]!.capacity = hint
      #expect(throws: CatalogError.self) { try ModelsDocument(json: JSONEncoder().encode(doc)) }
    }
  }

  @Test func oidcRequiresSignerAndAlternateCredentialKindsAreChecked() async throws {
    var doc = try groupDocument()
    doc.providers["openai"]!.auth = .oidc
    let catalog = ProviderCatalog(document: doc, credentials: CredentialResolver { _ in .apiKey("fixture") })
    await #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .oidcNotConfigured(provider: "openai"))) { try await catalog.validateGroupReadiness("work") }
    doc.providers["openai"]!.auth = nil
    let wrong = ProviderCatalog(document: doc, credentials: CredentialResolver { id in id == "openai" ? .chatGPT(accessToken: "fixture", accountID: "fixture") : .apiKey("fixture") })
    await #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .credentialMismatch(provider: "openai"))) { try await wrong.validateGroupReadiness("work") }
  }
}

@Suite struct ModelPlacementTests {
  let now = Date(timeIntervalSince1970: 100_000)

  func usage(_ used: Double, reset: Double = 118_000, weekly: Double? = nil) -> ModelUsageSnapshot {
    var windows: [ModelUsageSnapshot.Window] = [.init(name: "five_hour", usedPercent: used, resetsAt: reset)]
    if let weekly { windows.append(.init(name: "seven_day", usedPercent: weekly, resetsAt: 704_800)) }
    return ModelUsageSnapshot(observedAt: 100_000, windows: windows)
  }

  func pick(_ doc: ModelsDocument, _ snapshots: [String: ModelUsageSnapshot], reason: ModelPlacementReason = .create) throws -> ModelPlacement {
    try placeModelGroup(id: "work", group: doc.groups["work"]!, providers: doc.providers, usage: snapshots, now: now, reason: reason)
  }

  @Test func relativeCapacityBeatsRawPercentAndEvidenceIsRecorded() throws {
    var doc = try groupDocument()
    doc.providers["openai"]!.capacity = ["fiveHour": 4]
    let placed = try pick(doc, ["anthropic": usage(50), "openai": usage(70)], reason: .startOver)
    #expect(placed.member.id == "secondary")
    #expect(placed.reason == .startOver)
    #expect(abs(placed.evidence[1].windows[0].remaining - 1.2) < 0.00001)
    #expect(placed.evidence[0].score == 0.5)
  }

  @Test func resetTimeWeightsHeadroomAndWeeklyBottleneckWins() throws {
    let doc = try groupDocument()
    #expect(try pick(doc, ["anthropic": usage(50), "openai": usage(70, reset: 103_600)]).member.id == "secondary")
    #expect(try pick(doc, ["anthropic": usage(50, weekly: 99), "openai": usage(70, weekly: 10)]).member.id == "secondary")
    #expect(try pick(doc, ["anthropic": usage(100, reset: 99999), "openai": usage(70)]).member.id == "primary")
  }

  @Test func unknownRanksBelowKnownAndTiesAreStable() throws {
    var doc = try groupDocument()
    #expect(try pick(doc, ["openai": usage(99)]).member.id == "secondary")
    #expect(try pick(doc, [:]).member.id == "primary")
    doc.groups["work"]!.members.reverse()
    #expect(try pick(doc, [:], reason: .compaction).member.id == "primary")
    #expect(try pick(doc, ["anthropic": usage(50), "openai": usage(50)]).member.id == "primary")
  }

  @Test func exhaustedGroupsFailButUnknownAndSelectRemainUsable() throws {
    var doc = try groupDocument()
    #expect(throws: CatalogError.noUsableMembers("work")) { try pick(doc, ["anthropic": usage(100), "openai": usage(110)]) }
    #expect(try pick(doc, ["anthropic": usage(100)]).member.id == "secondary")
    doc.groups["work"]!.policy = .select(member: "primary")
    #expect(try pick(doc, ["anthropic": usage(100), "openai": usage(50)]).member.id == "primary")
  }
}

@Suite struct ModelGroupCapabilityTests {
  @Test func capabilityGroupOverridesFailBeforeCredentialsOrNetwork() async throws {
    let doc = try groupDocument()
    let json = try JSONEncoder().encode(doc)
    let groups = try JSONEncoder().encode(doc.groups)
    let client = try await CapabilityClient.load(read: { path in
      if path == ModelsDocument.spacePath { return json }
      if path == ModelsDocument.groupPath { return groups }
      return nil
    }, credentials: .unavailable)
    await #expect(throws: CapabilityError(.unsupportedTarget, "Model groups are session routing targets, not capability targets.")) {
      try await client.search("query", options: .init(provider: "work"))
    }
  }

  @Test func malformedCatalogDoesNotFallBackToCodex() async throws {
    await #expect(throws: CapabilityError(.providerNotConfigured, "Invalid or unreadable /models.json.")) {
      try await CapabilityClient.load(read: { path in path == "/models.json" ? Data("broken".utf8) : nil }, credentials: .unavailable)
    }
  }
}

extension ModelPlacementTests {
  @Test func staleExhaustedWindowBecomesFreshAtResetWithoutResettingWeeklyUsage() throws {
    let doc = try groupDocument()
    var gateway = usage(100, reset: 100_001, weekly: 15)
    gateway.observedAt = now.timeIntervalSince1970 - 57 * 60
    let other = usage(37, weekly: 49)
    #expect(try pick(doc, ["anthropic": gateway, "openai": other]).member.id == "secondary")
    gateway.windows[0].resetsAt = now.timeIntervalSince1970 - 1
    let placed = try pick(doc, ["anthropic": gateway, "openai": other])
    #expect(placed.member.id == "primary")
    let evidence = try #require(placed.evidence.first)
    #expect(evidence.windows[0].usedPercent == 100)
    #expect(evidence.windows[0].remaining == 1)
    #expect(evidence.windows[1].remaining == 0.85)
    #expect(evidence.score == 0.85)
  }
}

private struct Dev114Provider: Decodable {
  let dialect: String
  let baseURL: URL
  let originator: String?
  let transport: String?
  let auth: String?
  let models: [String: Model]

  struct Model: Decodable {
    let maxInput: Int
    let maxOutput: Int
    let efforts: [String]
    let defaultEffort: String
    let headroomOverride: Int?
  }
}

extension ModelGroupTests {
  @Test func providerOnlyEncodingRemainsReadableByFrozenDev114DecoderWithCapacityHints() throws {
    var doc = try groupDocument()
    doc.providers["anthropic"]!.capacity = ["fiveHour": 1, "sevenDay": 2]
    let data = try JSONEncoder().encode(doc)
    let legacy = try JSONDecoder().decode([String: Dev114Provider].self, from: data)
    #expect(legacy.keys.sorted() == doc.providers.keys.sorted())
    #expect(legacy["anthropic"]?.models["claude-sonnet-5"]?.defaultEffort == "high")
    #expect(legacy["work"] == nil)
    #expect(try ModelsDocument(json: data, groupsJSON: JSONEncoder().encode(doc.groups)) == doc)
  }

  @Test func separateGroupFileRejectsProviderNameClashesAndUnknownMembers() throws {
    var doc = try groupDocument()
    doc.groups["anthropic"] = doc.groups.removeValue(forKey: "work")
    #expect(throws: CatalogError.self) { try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups)) }
    doc = try groupDocument()
    doc.groups["work"]!.members[1].provider = "missing"
    #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .unknownProvider("missing"))) {
      try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups))
    }
  }
}

extension ModelGroupTests {
  @Test func providerCustomCodingPreservesCapacityAndReplayPolicyTogether() throws {
    var doc = try groupDocument()
    doc.providers["anthropic"]!.capacity = ["fiveHour": 3, "sevenDay": 4]
    doc.providers["anthropic"]!.opaqueReplay = .affine
    let decoded = try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups))
    #expect(decoded == doc)
    #expect(decoded.providers["anthropic"]?.capacity == ["fiveHour": 3, "sevenDay": 4])
    #expect(decoded.providers["anthropic"]?.opaqueReplay == .affine)
  }
}
