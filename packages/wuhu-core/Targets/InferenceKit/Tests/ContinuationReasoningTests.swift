import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import ModelProviders
import SessionDomain
import Synchronization
import Testing
import WuhuAI

@Suite(.deterministicDependencies) struct ContinuationReasoningTests {
  @Test(arguments: [false, true])
  func noReplayScopeIsSentWithThinkingNotRefused(carried: Bool) async throws {
    let body = try await emittedRequest(history(signed: false, carried: carried), scope: nil)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test func unsignedCurrentTurnWithoutBoundaryIsSentWithThinking() async throws {
    let body = try await emittedRequest(history(signed: false, carried: false))
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test func claudeAccountSwitchMidTurnStillDowngrades() async throws {
    let body = try await emittedRequest(history(signed: true, carried: true, scope: "previous-account"))
    #expect(body.object?["thinking"] == nil)
    #expect(!body.jsonString().contains("signed-thinking"))
  }

  @Test(arguments: [nil, "replay-handoff", "model-route"] as [String?], [false, true])
  func miMoAcrossPortableBoundaryKeepsConfiguredEffort(source: String?, signed: Bool) async throws {
    var lines = history(signed: signed, carried: true, scope: "previous-account")
    if let source { lines += boundaryNotice(source) }
    let body = try await emittedRequest(lines, claude: false)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test(arguments: [nil, "replay-handoff", "model-route"] as [String?])
  func nonClaudeModelOnAnthropicHostKeepsConfiguredEffort(source: String?) async throws {
    var lines = history(signed: true, carried: true, scope: "previous-account")
    if let source { lines += boundaryNotice(source) }
    let resolved = try await catalogModel(dialect: "anthropic", baseURL: "https://claude-format.invalid/v1", model: "glm-5.1")
    #expect(!resolved.isClaude)
    let body = try await emittedRequest(lines, resolved: resolved)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test func claudeModelBehindProxyHostDowngradesAfterMidTurnSwitch() async throws {
    var lines = history(signed: true, carried: true, scope: "previous-account")
    lines += boundaryNotice("replay-handoff")
    let resolved = try await catalogModel(dialect: "anthropic", baseURL: "https://egress.invalid/anthropic", model: "claude-sonnet-4-6")
    #expect(resolved.isClaude)
    let body = try await emittedRequest(lines, resolved: resolved)
    #expect(body.object?["thinking"] == nil)
    #expect(!body.jsonString().contains("signed-thinking"))
  }

  @Test func compactionPreservingSignedThinkingKeepsReasoningEnabled() async throws {
    let body = try await emittedRequest(history(signed: true, carried: true))
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
    #expect(body.jsonString().contains("signed-thinking"))
  }

  @Test func carriedUnsignedToolHistoryDisablesThinkingOnTheWire() async throws {
    let body = try await emittedRequest(history(signed: false, carried: true))
    #expect(body.object?["thinking"] == nil)
    #expect(body.object?["messages"]?.array?.contains { $0.object?["content"]?.array?.contains { $0.object?["type"]?.stringValue == "tool_use" } == true } == true)
  }

  @Test(arguments: [SystemNotification.Kind.timer, .spaceObservation, .context])
  func notificationStartsFreshReasoningTurn(kind: SystemNotification.Kind) async throws {
    var lines = history(signed: false, carried: true)
    lines += TranscriptItem.notification(.init(id: UUID(), timestamp: Date(), kind: kind, subscriptionID: .init(kind == .context ? "cache-warming" : "trigger"), content: .init(text: "fresh input"))).lines(session: .init("continuation-test"))
    let body = try await emittedRequest(lines)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test(arguments: ["replay-handoff", "model-route"])
  func onlySyntheticBoundaryNoticesPreserveSuppression(source: String) async throws {
    var lines = history(signed: false, carried: true)
    lines += boundaryNotice(source)
    let body = try await emittedRequest(lines)
    #expect(body.object?["thinking"] == nil)
  }

  @Test func conversationMessageStartsAFreshReasoningTurn() async throws {
    let lines = history(signed: false, carried: true) + [TranscriptLine(at: Date(), key: "message:fresh", message: .user(.init(content: [.text("continue")])))]
    let body = try await emittedRequest(lines)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  private func boundaryNotice(_ source: String) -> [TranscriptLine] {
    TranscriptItem.notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init(source), content: .init(text: "boundary continuation"))).lines(session: .init("continuation-test"))
  }

  private func emittedRequest(_ lines: [TranscriptLine], scope: String? = "scope", claude: Bool = true, resolved: ResolvedModel? = nil) async throws -> JSONValue {
    let bodies = Mutex<[JSONValue]>([])
    try await withDependencies {
      $0.continuousClock = ContinuousClock()
      $0.date = DateGenerator { Date() }
      $0.fetch = FetchClient { request in
        let body = try await request.body?.json(JSONValue.self) ?? .null
        bodies.withLock { $0.append(body) }
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"index":0,"delta":{"type":"text_delta","text":"done"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      }
    } operation: {
      let model = resolved ?? self.model(scope: scope, claude: claude)
      _ = try await InferenceExecutor(session: .init("continuation-test"), model: model, systemPrompt: "test", tools: []).run(attemptID: UUID(), lines: lines)
    }
    return try #require(bodies.withLock { $0.first })
  }

  private func model(scope: String?, claude: Bool) -> ResolvedModel {
    let name = claude ? "claude-test" : "mimo-v2.6-pro"
    return .init(specifier: .init(provider: "testing", model: name, effort: "high"), endpoint: AnthropicEndpoint(model: name, replayScope: scope, baseURL: URL(string: "http://localhost:1")!, apiKey: "fake"), budget: .init(maxInput: 10000, maxOutput: 1000), replayScope: scope)
  }

  private func catalogModel(dialect: String, baseURL: String, model: String) async throws -> ResolvedModel {
    let document = try ModelsDocument(json: Data("""
    {"p":{"dialect":"\(dialect)","baseURL":"\(baseURL)","opaqueReplay":"affine","models":{"\(model)":{"maxInput":10000,"maxOutput":1000,"efforts":["high"],"defaultEffort":"high"}}}}
    """.utf8))
    let catalog = ProviderCatalog(document: document, credentials: .bound { _ in .init(credential: .apiKey("fake"), identityEpoch: "current-account") })
    let resolved = try await catalog.resolve(.init(provider: "p", model: model, effort: "high"), session: .init("continuation-test"))
    #expect(resolved.endpoint is any AnthropicMessagesEndpoint)
    #expect(resolved.replayScope != nil)
    return resolved
  }

  private func history(signed: Bool, carried: Bool, scope: String = "scope") -> [TranscriptLine] {
    let call = ToolCall(id: "call", name: "read", arguments: .object([:]))
    let user = TranscriptLine(at: Date(), key: "message:initial", message: .user(.init(content: [.text("test")])))
    let items: [TranscriptItem] = [
      .assistant(.init(id: UUID(), timestamp: Date(), content: (signed ? [.reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "reason", opaque: "signed-thinking", replayScope: scope)))] : []) + [.toolCall(call)], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: ["call": .init("call")], replayBinding: .init(identity: "scope", epoch: "route"))),
      .toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init("call")), payload: .failure(.init(message: "receipt")))),
    ]
    let lines = [user] + items.flatMap { $0.lines(session: .init("continuation-test")) }
    return carried ? lines.compactMap { $0.carried(portable: false) } : lines
  }
}
