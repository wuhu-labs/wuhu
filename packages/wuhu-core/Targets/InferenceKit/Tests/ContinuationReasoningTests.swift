import Dependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import Synchronization
import Testing
import WuhuAI

@Suite struct ContinuationReasoningTests {
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

  @Test(arguments: [nil, "replay-handoff", "model-route", "legacy-handoff"] as [String?], [false, true])
  func miMoAcrossPortableBoundaryKeepsConfiguredEffort(source: String?, signed: Bool) async throws {
    var transcript = history(signed: signed, carried: true, scope: "previous-account")
    if let source { transcript.append(boundaryNotice(source)) }
    let body = try await emittedRequest(transcript, claude: false)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  /// A non-Claude model behind a custom `claude`-dialect host is not under
  /// Claude's rule: the dialect never decides it.
  @Test(arguments: [nil, "replay-handoff", "model-route"] as [String?])
  func nonClaudeModelOnClaudeDialectHostKeepsConfiguredEffort(source: String?) async throws {
    var transcript = history(signed: true, carried: true, scope: "previous-account")
    if let source { transcript.append(boundaryNotice(source)) }
    let resolved = try await catalogModel(dialect: "claude", baseURL: "https://claude-format.invalid/v1", model: "glm-5.1")
    #expect(!resolved.isClaude)
    let body = try await emittedRequest(transcript, resolved: resolved)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  /// Claude served by a proxy host is still under Claude's rule: the host
  /// never decides it.
  @Test(arguments: ["anthropic", "claude"])
  func claudeModelBehindProxyHostDowngradesAfterMidTurnSwitch(dialect: String) async throws {
    var transcript = history(signed: true, carried: true, scope: "previous-account")
    transcript.append(boundaryNotice("replay-handoff"))
    let resolved = try await catalogModel(dialect: dialect, baseURL: "https://egress.invalid/anthropic", model: "claude-sonnet-4-6")
    #expect(resolved.isClaude)
    let body = try await emittedRequest(transcript, resolved: resolved)
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
    var transcript = history(signed: false, carried: true)
    transcript.append(.notification(.init(id: UUID(), timestamp: Date(), kind: kind, subscriptionID: .init(kind == .context ? "cache-warming" : "trigger"), content: .init(text: "fresh input"))))
    let body = try await emittedRequest(transcript)
    #expect(body.object?["thinking"]?.object?["type"]?.stringValue == "adaptive")
  }

  @Test(arguments: ["replay-handoff", "model-route", "legacy-handoff", "legacy-route", "empty-context"])
  func onlySyntheticBoundaryNoticesPreserveSuppression(source: String) async throws {
    var transcript = history(signed: false, carried: true)
    transcript.append(boundaryNotice(source))
    let body = try await emittedRequest(transcript)
    #expect(body.object?["thinking"] == nil)
  }

  private func boundaryNotice(_ source: String) -> TranscriptItem {
    let text: String
    switch source {
    case "legacy-handoff": text = "Portable replay handoff completed. Earlier tool calls have their committed receipts; do not execute them again. This is a fresh account-neutral turn. Continue the outstanding request using the full carried input; re-read files/history as needed."
    case "legacy-route": text = "Model group work moved a → b (quota). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."
    case "empty-context": text = ""
    default: text = "boundary continuation"
    }
    return .notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init(source.hasPrefix("legacy-") || source == "empty-context" ? "context" : source), content: .init(text: text)))
  }

  private func emittedRequest(_ transcript: Transcript, scope: String? = "scope", claude: Bool = true, resolved: ResolvedModel? = nil) async throws -> JSONValue {
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
      _ = try await InferenceExecutor(session: .init("continuation-test"), model: model, systemPrompt: "test", tools: []).run(attemptID: UUID(), transcript: transcript, mode: .normal)
    }
    return try #require(bodies.withLock { $0.first })
  }

  /// `claude` picks a Claude model id; otherwise the same Anthropic-dialect
  /// endpoint at the same host serves a MiMo model.
  private func model(scope: String?, claude: Bool) -> ResolvedModel {
    let name = claude ? "claude-test" : "mimo-v2.6-pro"
    return .init(specifier: .init(provider: "testing", model: name, effort: "high"), endpoint: AnthropicEndpoint(model: name, replayScope: scope, baseURL: URL(string: "http://localhost:1")!, apiKey: "fake"), budget: .init(maxInput: 10000, maxOutput: 1000), replayScope: scope)
  }

  /// A model resolved from a one-provider catalog, as a session would get it.
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

  private func history(signed: Bool, carried: Bool, scope: String = "scope") -> Transcript {
    let call = ToolCall(id: "call", name: "read", arguments: .object([:]))
    let items: [TranscriptItem] = [
      .direct(.init(id: UUID(), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "test"))),
      .assistant(.init(id: UUID(), timestamp: Date(), content: (signed ? [.reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "reason", opaque: "signed-thinking", replayScope: scope)))] : []) + [.toolCall(call)], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: ["call": .init("call")], replayBinding: .init(identity: "scope", epoch: "route"))),
      .toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init("call")), payload: .failure(.init(message: "receipt")))),
    ]
    return Transcript(items: items, keptCount: carried ? items.count : 0)
  }
}
