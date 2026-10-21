import JSONValue
import SessionDomain
import Testing

@Suite struct ExecutorTests {
  static let model = ModelSpecifier(provider: "anthropic", model: "claude", effort: "high")

  @Test func kernelRoundTripsThroughTheColumnPair() throws {
    let executor = SessionExecutor.kernel(Self.model)
    #expect(executor.kind == "kernel")
    let decoded = try SessionExecutor(kind: executor.kind, configJSON: executor.configJSON)
    #expect(decoded == executor)
  }

  @Test func aRetiredKindKeepsItsStoredString() throws {
    let decoded = try SessionExecutor(kind: "claude-code", configJSON: "{}")
    #expect(decoded == .retired(kind: "claude-code"))
    #expect(decoded.kind == "claude-code")
    #expect(decoded.isRetired)
    #expect(throws: ExecutorUnavailableError()) { try decoded.requireSupported() }
  }

  @Test func anArchivedContractorRowStillDecodes() throws {
    let decoded = try SessionExecutor(
      kind: "contractor:opus-box",
      configJSON: #"{"model":"claude-opus-5","effort":"max","extra":{"cwd":"/work"}}"#,
    )
    #expect(decoded == .retired(kind: "contractor:opus-box"))
    #expect(decoded.kind == "contractor:opus-box")
  }

  @Test func anUnknownKindDecodesAsRetired() throws {
    let decoded = try SessionExecutor(kind: "daemon", configJSON: #"{"provider":"a","model":"m","effort":"high"}"#)
    #expect(decoded == .retired(kind: "daemon"))
  }

  @Test func kernelConfigRejectsJunk() {
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "kernel", configJSON: #"{"provider":"a","model":"m","effort":"high","advisor":"x"}"#)
    }
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "kernel", configJSON: #"{"provider":"a","model":"m"}"#)
    }
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "kernel", configJSON: #"{"provider":"a","model":"m","effort":3}"#)
    }
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "kernel", configJSON: "[]")
    }
  }

  @Test func explicitParamsOverrideTemplateValues() {
    let template = SessionCreationParams(provider: "a", model: "template-model", effort: "low", tags: ["template"])
    let merged = SessionCreationParams(effort: "max", tags: []).merged(over: template)
    #expect(merged == SessionCreationParams(provider: "a", model: "template-model", effort: "max", tags: []))
  }

  @Test func templateFieldsAreEnvelopeValidated() throws {
    let params = try SessionCreationParams(templateFields: [
      "provider": "a", "model": "m", "tags": .array(["a"]),
    ])
    #expect(params == SessionCreationParams(provider: "a", model: "m", tags: ["a"]))
    #expect(throws: ExecutorSpecError.self) {
      try SessionCreationParams(templateFields: ["identity": "owner"])
    }
    #expect(throws: ExecutorSpecError.self) {
      try SessionCreationParams(templateFields: ["tags": "a"])
    }
    #expect(throws: ExecutorSpecError.self) {
      try SessionCreationParams(templateFields: ["executor": "unknown"])
    }
  }

  @Test func theProviderDialectPicksTheExecutor() async throws {
    func resolveModelExecutor(_ provider: String, _ model: String, _ effort: String?) async throws -> SessionExecutor {
      .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "default"))
    }

    let kernel = try await SessionExecutor.resolve(
      SessionCreationParams(provider: "a", model: "m"), resolveModelExecutor: resolveModelExecutor,
    )
    #expect(kernel == .kernel(ModelSpecifier(provider: "a", model: "m", effort: "default")))
    await #expect(throws: ExecutorSpecError.self) {
      try await SessionExecutor.resolve(SessionCreationParams(model: "m"), resolveModelExecutor: resolveModelExecutor)
    }
  }
}

@Suite struct GroupExecutorTests {
  @Test func groupIntentRoundTripsWithoutConcretePin() throws {
    let executor = SessionExecutor.modelGroup(id: "work", effort: "high")
    #expect(executor.kind == "kernel")
    #expect(try SessionExecutor(kind: executor.kind, configJSON: executor.configJSON) == executor)
    #expect(throws: ExecutorSpecError.self) { try SessionExecutor(kind: "kernel", configJSON: #"{"modelGroup":"work","provider":"a","model":"m","effort":"high"}"#) }
  }

  @Test func overridesReplaceTargetAndTemplatesKeepEffortOnlyOnSameTarget() throws {
    let direct = SessionCreationParams(provider: "a", model: "m", effort: "low")
    #expect(SessionCreationParams(modelGroup: "work").merged(over: direct) == .init(modelGroup: "work"))
    let group = SessionCreationParams(modelGroup: "work", effort: "high")
    #expect(SessionCreationParams(provider: "a", model: "m").merged(over: group) == .init(provider: "a", model: "m"))
    #expect(SessionCreationParams(effort: "low").merged(over: group) == .init(modelGroup: "work", effort: "low"))
    #expect(try SessionCreationParams(templateFields: ["modelGroup": "work", "effort": "high"]) == group)
    #expect(throws: ExecutorSpecError.self) { try SessionCreationParams(templateFields: ["modelGroup": "work", "provider": "a"]) }
  }
}
