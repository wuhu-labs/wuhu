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

  @Test func claudeCodeRoundTripsThroughTheColumnPair() throws {
    let executor = SessionExecutor.claudeCode(Self.model)
    #expect(executor.kind == "claude-code")
    #expect(try SessionExecutor(kind: executor.kind, configJSON: executor.configJSON) == executor)
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "claude-code", configJSON: #"{"provider":"a","model":"m"}"#)
    }
  }

  @Test func anArchivedContractorRowStillDecodes() throws {
    let decoded = try SessionExecutor(
      kind: "contractor:opus-box",
      configJSON: #"{"model":"claude-opus-5","effort":"max","extra":{"cwd":"/work"}}"#,
    )
    #expect(decoded == .contractor(name: "opus-box"))
    #expect(decoded.kind == "contractor:opus-box")
  }

  @Test func unknownExecutorsAreRefused() {
    #expect(throws: ExecutorSpecError.self) {
      try SessionExecutor(kind: "daemon", configJSON: #"{"provider":"a","model":"m","effort":"high"}"#)
    }
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
      let specifier = ModelSpecifier(provider: provider, model: model, effort: effort ?? "default")
      return provider == "claude" ? .claudeCode(specifier) : .kernel(specifier)
    }

    let kernel = try await SessionExecutor.resolve(
      SessionCreationParams(provider: "a", model: "m"), resolveModelExecutor: resolveModelExecutor,
    )
    #expect(kernel == .kernel(ModelSpecifier(provider: "a", model: "m", effort: "default")))
    await #expect(throws: ExecutorUnavailableError()) {
      try await SessionExecutor.resolve(
        SessionCreationParams(provider: "claude", model: "opus"), resolveModelExecutor: resolveModelExecutor,
      )
    }
    await #expect(throws: ExecutorSpecError.self) {
      try await SessionExecutor.resolve(SessionCreationParams(model: "m"), resolveModelExecutor: resolveModelExecutor)
    }
  }
}
