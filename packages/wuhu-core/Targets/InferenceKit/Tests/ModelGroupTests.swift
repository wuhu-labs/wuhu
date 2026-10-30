import Credentials
import DeterministicDependencies
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

@Suite(.deterministicDependencies) struct ModelGroupTests {
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
    let document = try ModelsDocument(json: fixtureJSON, groupsJSON: Data(json.utf8))
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: document, credentials: .unavailable).validateGroup("work") }
  }

  @Test func allMembersAndDefaultEffortAreValidated() async throws {
    let doc = try groupDocument(policy: .select(member: "primary"))
    let catalog = ProviderCatalog(document: doc, credentials: CredentialResolver { provider in
      provider == "anthropic" ? .apiKey("fixture") : nil
    })
    await #expect(throws: CatalogError.groupMember(group: "work", member: "secondary", reason: .missingCredential(provider: "openai"))) {
      try await catalog.validateGroupReadiness("work")
    }
    let validated = try catalog.validatedGroup("work", effort: "max")
    #expect(validated.declaration.members.map(\.id) == ["primary"])
    #expect(validated.memberErrors["secondary"] == .groupMember(group: "work", member: "secondary", reason: .unknownEffort(provider: "openai", model: "gpt-5.4", effort: "max")))
    #expect(try catalog.validateGroup("work", effort: "max") == "max")
    var bad = doc
    bad.groups["work"]!.defaultEffort = "max"
    #expect(try ProviderCatalog(document: bad, credentials: .unavailable).validateGroup("work", effort: "high") == "high")
  }

  @Test func duplicateDeclarationsFailButInvalidMembersAreExcluded() throws {
    var doc = try groupDocument()
    doc.groups["work"]!.members[1].id = "primary"
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: doc, credentials: .unavailable).validateGroup("work") }
    doc = try groupDocument()
    doc.groups["work"]!.members[1].provider = "work"
    let nested = try ProviderCatalog(document: doc, credentials: .unavailable).validatedGroup("work")
    #expect(nested.declaration.members.map(\.id) == ["primary"])
    #expect(nested.memberErrors["secondary"] == .groupMember(group: "work", member: "secondary", reason: .unsupportedTarget("work")))
    doc = try groupDocument()
    doc.providers["openai"]!.models["gpt-5.4"]!.maxOutput = 400_000
    let budget = try ProviderCatalog(document: doc, credentials: .unavailable).validatedGroup("work")
    #expect(budget.declaration.members.map(\.id) == ["primary"])
    #expect(budget.memberErrors["secondary"] == .groupMember(group: "work", member: "secondary", reason: .invalidModel(provider: "openai", model: "gpt-5.4")))
    doc.groups["work"]!.policy = .select(member: "secondary")
    #expect(throws: budget.memberErrors["secondary"]!) { try ProviderCatalog(document: doc, credentials: .unavailable).validateGroup("work") }
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
    doc.providers["anthropic"]!.capacity = ["five_hour": 4]
    #expect(try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") == route.specifier)
    doc.providers["anthropic"]!.baseURL = URL(string: "https://other.example/v1")!
    #expect(throws: CatalogError.modelRouteInvalid(group: "work", member: "primary")) { try ProviderCatalog(document: doc, credentials: .unavailable).validateRoute(route, group: "work", effort: "high") }
  }

  @Test func capacityHintsAreValidatedAndConcreteOperationsRefuseGroups() throws {
    var doc = try groupDocument()
    let spec = ModelSpecifier(provider: "work", model: "ignored", effort: "high")
    #expect(throws: CatalogError.unsupportedTarget("work")) { try ProviderCatalog(document: doc, credentials: .unavailable).validate(spec) }
    for hint: [String: Double] in [["five_hour": 0], ["seven_day": -1], ["": 2]] {
      doc.providers["openai"]!.capacity = hint
      let decoded = try ModelsDocument(json: JSONEncoder().encode(doc))
      #expect(throws: CatalogError.self) { try ProviderCatalog(document: decoded, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "high")) }
    }
  }

  @Test func capacitiesMustBindAtLeastOneProviderModel() throws {
    var doc = try groupDocument()
    for key in ["unbound", "fiveHour", "sevenDay"] {
      doc.providers["openai"]!.capacity = [key: 2]
      let decoded = try ModelsDocument(json: JSONEncoder().encode(doc))
      #expect(throws: CatalogError.invalidCapacity(provider: "openai", window: key)) {
        try ProviderCatalog(document: decoded, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "high"))
      }
    }
    doc.providers["openai"]!.models["gpt-5.4"]!.usageWindows = ["model_week"]
    doc.providers["openai"]!.capacity = ["model_week": 2]
    #expect(try ModelsDocument(json: JSONEncoder().encode(doc)).providers == doc.providers)
    doc.providers["openai"]!.capacity = ["five_hour": 2]
    let unbound = try ModelsDocument(json: JSONEncoder().encode(doc))
    #expect(throws: CatalogError.invalidCapacity(provider: "openai", window: "five_hour")) {
      try ProviderCatalog(document: unbound, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "high"))
    }
    doc.providers["openai"]!.models["another"] = .init(maxInput: 1000, maxOutput: 100, efforts: ["high"], defaultEffort: "high")
    #expect(try ModelsDocument(json: JSONEncoder().encode(doc)).providers == doc.providers)
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

@Suite(.deterministicDependencies) struct ModelPlacementTests {
  let now = Date(timeIntervalSince1970: 100_000)

  func usage(_ used: Double, reset: Double = 118_000, weekly: Double = 0, weeklyReset: Double = 704_800) -> ModelUsageSnapshot {
    ModelUsageSnapshot(observedAt: 100_000, windows: [
      .init(name: "five_hour", usedPercent: used, resetsAt: reset),
      .init(name: "seven_day", usedPercent: weekly, resetsAt: weeklyReset),
    ])
  }

  func pick(_ doc: ModelsDocument, _ snapshots: [String: ModelUsageSnapshot], reason: ModelPlacementReason = .create) throws -> ModelPlacement {
    try placeModelGroup(id: "work", group: doc.groups["work"]!, providers: doc.providers, usage: snapshots, now: now, reason: reason)
  }

  @Test func relativeCapacityBeatsRawPercentAndEvidenceIsRecorded() throws {
    var doc = try groupDocument()
    doc.providers["openai"]!.capacity = ["seven_day": 4]
    let placed = try pick(doc, ["anthropic": usage(50, weekly: 50), "openai": usage(70, weekly: 70)], reason: .startOver)
    #expect(placed.member.id == "secondary")
    #expect(placed.reason == .startOver)
    #expect(abs(try #require(placed.evidence[1].windows[1].remaining) - 1.2) < 0.00001)
    #expect(placed.evidence[0].score == 0.5)
  }

  @Test func aFreshSmallMemberBeatsALargeOneWhoseSevenDayBurnsSlower() throws {
    var doc = try groupDocument()
    doc.providers["openai"]!.capacity = ["five_hour": 4, "seven_day": 2]
    let placed = try pick(doc, ["anthropic": usage(0, weekly: 7, weeklyReset: 301_600), "openai": usage(2, weekly: 2)])
    #expect(placed.member.id == "primary")
    #expect(abs(try #require(placed.evidence[0].score) - 2.79) < 0.00001)
    #expect(abs(try #require(placed.evidence[1].score) - 1.96) < 0.00001)
    #expect(abs(try #require(placed.evidence[1].windows[0].score) - 3.92) < 0.00001, "a fresh five-hour window still records its score")
  }

  @Test func theSevenDayResetWeightsHeadroomAndAFullFiveHourWindowExcludes() throws {
    let doc = try groupDocument()
    #expect(try pick(doc, ["anthropic": usage(0, weekly: 50), "openai": usage(0, weekly: 70, weeklyReset: 251_200)]).member.id == "secondary")
    #expect(try pick(doc, ["anthropic": usage(50, weekly: 99), "openai": usage(70, weekly: 10)]).member.id == "secondary")
    let capped = try pick(doc, ["anthropic": usage(100), "openai": usage(0, weekly: 90)])
    #expect(capped.member.id == "secondary")
    #expect(capped.evidence[0].score == 0)
  }

  @Test func twoSevenDayWindowsRankByTheirMinimum() throws {
    var doc = try groupDocument()
    doc.providers["anthropic"]!.models["claude-sonnet-5"]!.usageWindows = ["five_hour", "seven_day", "seven_day_overage_included"]
    var fable = usage(0, weekly: 10)
    fable.windows.append(.init(name: "seven_day_overage_included", usedPercent: 80, resetsAt: 704_800, windowMinutes: 10080))
    let placed = try pick(doc, ["anthropic": fable, "openai": usage(0, weekly: 50)])
    #expect(placed.member.id == "secondary")
    #expect(abs(try #require(placed.evidence[0].score) - 0.2) < 0.00001)
    fable.windows[2].usedPercent = 0
    #expect(try pick(doc, ["anthropic": fable, "openai": usage(0, weekly: 50)]).member.id == "primary")
  }

  @Test func configuredWindowsBindOnlyTheirModelAndUseReportedDurations() throws {
    var doc = try groupDocument()
    let bindings = ["five_hour", "seven_day", "model_week"]
    for provider in ["anthropic", "openai"] {
      let model = doc.groups["work"]!.members.first { $0.provider == provider }!.model
      doc.providers[provider]!.models[model]!.usageWindows = bindings
    }
    var left = usage(10, weekly: 10)
    left.windows.append(.init(name: "model_week", usedPercent: 100, resetsAt: 704_800, windowMinutes: 10080))
    var right = usage(50, weekly: 50)
    right.windows.append(.init(name: "model_week", usedPercent: 40, resetsAt: 402_400, windowMinutes: 10080))
    let snapshots = ["anthropic": left, "openai": right]
    let placed = try pick(doc, snapshots)
    #expect(placed.member.id == "secondary")
    #expect(placed.evidence.map { $0.windows.map(\.name) } == [bindings, bindings])
    #expect(placed.evidence[0].score == 0)
    #expect(placed.evidence[1].windows.last?.score == 1.2)
    #expect(try ModelsDocument(json: JSONEncoder().encode(doc)).providers == doc.providers)
    for provider in ["anthropic", "openai"] {
      let model = doc.groups["work"]!.members.first { $0.provider == provider }!.model
      doc.providers[provider]!.models[model]!.usageWindows = nil
    }
    #expect(try pick(doc, snapshots).member.id == "primary")
    doc.providers["anthropic"]!.models["claude-sonnet-5"]!.usageWindows = ["model_week"]
    doc.providers["openai"]!.models["gpt-5.4"]!.usageWindows = ["model_week"]
    left.windows[left.windows.count - 1].usedPercent = 60
    left.windows[left.windows.count - 1].resetsAt = 704_800
    doc.providers["anthropic"]!.capacity = ["model_week": 4]
    #expect(try pick(doc, ["anthropic": left, "openai": right]).member.id == "primary")
  }

  @Test func anUnobservedBindingMakesTheWholeMemberUnknown() throws {
    var doc = try groupDocument()
    for provider in ["anthropic", "openai"] {
      let model = doc.groups["work"]!.members.first { $0.provider == provider }!.model
      doc.providers[provider]!.models[model]!.usageWindows = ["five_hour", "seven_day", "model_week"]
    }
    var known = usage(50, weekly: 50)
    known.windows.append(.init(name: "model_week", usedPercent: 50, resetsAt: 704_800, windowMinutes: 10080))
    let placed = try pick(doc, ["anthropic": usage(10, weekly: 10), "openai": known])
    #expect(placed.member.id == "secondary")
    #expect(placed.evidence[0].score == nil)
    let unseen = try #require(placed.evidence[0].windows.last)
    #expect(unseen.name == "model_week")
    #expect(unseen.usedPercent == nil && unseen.remaining == nil && unseen.score == nil)
    let roundTrip = try JSONDecoder().decode(ModelPlacementEvidence.self, from: JSONEncoder().encode(placed.evidence[0]))
    #expect(roundTrip == placed.evidence[0])
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

@Suite(.deterministicDependencies) struct ModelGroupCapabilityTests {
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
    doc.providers["anthropic"]!.capacity = ["five_hour": 1, "seven_day": 2]
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
    let decoded = try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups))
    #expect(throws: CatalogError.self) { try ProviderCatalog(document: decoded, credentials: .unavailable).validateGroup("anthropic") }
    doc = try groupDocument()
    doc.groups["work"]!.members[1].provider = "missing"
    let missing = try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups))
    let validated = try ProviderCatalog(document: missing, credentials: .unavailable).validatedGroup("work")
    #expect(validated.declaration.members.map(\.id) == ["primary"])
    #expect(validated.memberErrors["secondary"] == .groupMember(group: "work", member: "secondary", reason: .unknownProvider("missing")))
  }
}

extension ModelGroupTests {
  @Test func providerCustomCodingPreservesCapacityAndReplayPolicyTogether() throws {
    var doc = try groupDocument()
    doc.providers["anthropic"]!.capacity = ["five_hour": 3, "seven_day": 4]
    doc.providers["anthropic"]!.opaqueReplay = .affine
    let decoded = try ModelsDocument(json: JSONEncoder().encode(doc), groupsJSON: JSONEncoder().encode(doc.groups))
    #expect(decoded == doc)
    #expect(decoded.providers["anthropic"]?.capacity == ["five_hour": 3, "seven_day": 4])
    #expect(decoded.providers["anthropic"]?.opaqueReplay == .affine)
  }
}
