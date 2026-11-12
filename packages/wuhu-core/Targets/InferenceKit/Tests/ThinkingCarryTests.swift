import Credentials
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

@Suite(.deterministicDependencies) struct ThinkingCarryTests {
  @Test(arguments: [false, true])
  func miMoUnsignedThinkingIsSentThroughEveryToolStep(oidc: Bool) async throws {
    let loop = try await toolLoop(.mimo, oidc: oidc)
    #expect(loop.bodies.count == 5, "Every step is sent; none is refused")
    for body in loop.bodies {
      #expect(body.object?["thinking"]?.object?["type"] == .string("adaptive"), "Configured effort holds on every step")
    }
    let assistants = try assistantMessages(loop.bodies.last)
    #expect(assistants.count == 4)
    for content in assistants {
      #expect(content.first?.object?["type"] == .string("thinking"))
      #expect(content.first?.object?["thinking"] == .string("Inspect the repository"))
      #expect(content.first?.object?["signature"] == nil)
    }
  }

  @Test func sameScopeSignedClaudeInterleavingIsReplayedAsReceived() async throws {
    let loop = try await toolLoop(.claude)
    #expect(loop.bodies.count == 5)
    let assistants = try assistantMessages(loop.bodies.last)
    #expect(assistants.count == 4)
    for content in assistants {
      #expect(content.first?.object?["type"] == .string("thinking"))
      #expect(content.first?.object?["signature"] == .string("fixture-signature"))
    }
  }

  @Test func crossScopeClaudeSignaturesAreStrippedAndTheRequestIsStillSent() async throws {
    let loop = try await toolLoop(.claude)
    let body = try await sendOnce(loop.lines, provider: .claude, account: "other-account")
    #expect(body.object?["thinking"]?.object?["type"] == .string("adaptive"), "Not carried across a boundary: nothing to downgrade, nothing refused")
    #expect(!body.jsonString().contains("fixture-signature"))
    for content in try assistantMessages(body) {
      #expect(content.first?.object?["type"] == .string("text"))
      #expect(content.first?.object?["text"] == .string("Inspect the repository"))
    }
  }

  @Test func crossScopeMiMoThinkingTravelsAsPlainThinking() async throws {
    let loop = try await toolLoop(.mimo)
    let body = try await sendOnce(loop.lines, provider: .mimo, account: "other-account")
    #expect(body.object?["thinking"]?.object?["type"] == .string("adaptive"))
    for content in try assistantMessages(body) {
      #expect(content.first?.object?["type"] == .string("thinking"))
      #expect(content.first?.object?["thinking"] == .string("Inspect the repository"))
      #expect(content.first?.object?["signature"] == nil)
    }
  }

  @Test func retiredAcceptsUnsignedThinkingKeyIsIgnored() async throws {
    let json = """
    {"mimo":{"dialect":"anthropic","baseURL":"https://api.xiaomimimo.com/anthropic","opaqueReplay":"affine","acceptsUnsignedThinking":true,
      "models":{"mimo-v2.6-pro":{"maxInput":1048576,"maxOutput":65536,"efforts":["medium"],"defaultEffort":"medium"}}},
     "gateway":{"dialect":"responses","baseURL":"https://gateway.invalid/v1","acceptsUnsignedThinking":"yes",
      "models":{"m":{"maxInput":1000,"maxOutput":100,"efforts":["low"],"defaultEffort":"low"}}}}
    """
    let document = try ModelsDocument(json: Data(json.utf8))
    #expect(document == ProviderCatalogFixture.document(.mimo).merging(gateway: document.providers["gateway"]))
    let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    #expect(!encoded.contains("acceptsUnsignedThinking"))
    let model = try await ProviderCatalogFixture.catalog(document).resolve(.init(provider: "mimo", model: "mimo-v2.6-pro", effort: "medium"), session: .init("fixture"))
    #expect(!model.isClaude)
    _ = try ProviderCatalog(document: document, credentials: .unavailable).validate(.init(provider: "gateway", model: "m", effort: "low"))
  }

  @Test(arguments: [
    ("claude-opus-5-5[1m]", true),
    ("claude-sonnet-4-6", true),
    ("anthropic/claude-sonnet-4-6", true),
    ("us.anthropic.claude-haiku-4-5-v1:0", true),
    ("Claude-Opus-5-5", true),
    ("mimo-v2.6-pro", false),
    ("deepseek-v4-pro", false),
    ("glm-5.1", false),
    ("claudette", false),
    ("test-model", false),
  ])
  func claudeIsDecidedFromTheModelID(model: String, claude: Bool) {
    #expect(ModelSpecifier.isClaudeModel(model) == claude)
  }

  private struct Loop {
    var bodies: [JSONValue]
    var lines: [TranscriptLine]
  }

  private func assistantMessages(_ body: JSONValue?) throws -> [[JSONValue]] {
    let messages = try #require(body?.object?["messages"]?.array)
    return messages.compactMap { message in
      guard message.object?["role"] == .string("assistant") else { return nil }
      return message.object?["content"]?.array
    }
  }

  private func toolLoop(_ provider: ProviderCatalogFixture.Provider, oidc: Bool = false) async throws -> Loop {
    var document = ProviderCatalogFixture.document(provider)
    document.providers[provider.id]?.auth = oidc ? .oidc : nil
    let model = try await ProviderCatalogFixture.catalog(document).resolve(.init(provider: provider.id, model: provider.model, effort: "medium"), session: .init("fixture"))
    #expect(model.isClaude == (provider == .claude))
    let bodies = Mutex<[JSONValue]>([])
    var lines = [TranscriptLine(at: Date(), key: "message:inspect", message: .user(.init(content: [.text("Inspect using tools")])))]
    let executor = InferenceExecutor(session: .init("fixture"), model: model, systemPrompt: "test", tools: [.function(name: "read", description: "Inspect", parameters: .object([:]))])
    try await withDependencies {
      $0.continuousClock = ContinuousClock()
      $0.date = DateGenerator { Date() }
      $0.fetch = FetchClient { request in
        let body = try #require(try await request.body?.json(JSONValue.self))
        let messages = try #require(body.object?["messages"]?.array)
        for (index, message) in messages.enumerated() where message.object?["role"] == .string("assistant") {
          let calls = message.object?["content"]?.array?.filter { $0.object?["type"] == .string("tool_use") } ?? []
          guard !calls.isEmpty else { continue }
          let results = try #require(messages[index + 1].object?["content"]?.array)
          #expect(calls.compactMap { $0.object?["id"] } == results.compactMap { $0.object?["tool_use_id"] })
        }
        let step = bodies.withLock { $0.append(body); return $0.count }
        return Response(status: .ok, body: .string(toolStepResponse(step: step, signed: provider == .claude, model: provider.model)))
      }
    } operation: {
      for step in 1 ... 5 {
        let completed = try await executor.run(attemptID: UUID(), lines: lines)
        if step == 5 { break }
        guard case let .reasoning(.encrypted(thinking))? = completed.message.content.first else {
          Issue.record("Missing recorded-shape thinking"); return
        }
        #expect(thinking.opaque == (provider == .claude ? "fixture-signature" : ""))
        #expect(thinking.replayScope == model.replayScope)
        let entry = AssistantEntry(completed.message, id: UUID(), at: Date(), metadata: completed.metadata, replayBinding: .init(identity: model.bindingIdentity, epoch: "route"), mint: { ToolCallID(UUID().uuidString) })
        lines += TranscriptItem.assistant(entry).lines(session: executor.session)
        for call in entry.toolCalls {
          lines += TranscriptItem.toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init(call.id)), payload: .failure(.init(message: "fixture receipt")))).lines(session: executor.session)
        }
        lines += notice("step \(step)").lines(session: executor.session)
      }
    }
    return Loop(bodies: bodies.withLock { $0 }, lines: lines)
  }

  private func sendOnce(_ lines: [TranscriptLine], provider: ProviderCatalogFixture.Provider, account: String) async throws -> JSONValue {
    let model = try await ProviderCatalogFixture.catalog(ProviderCatalogFixture.document(provider), account: account).resolve(.init(provider: provider.id, model: provider.model, effort: "medium"), session: .init("fixture"))
    let executor = InferenceExecutor(session: .init("fixture"), model: model, systemPrompt: "test", tools: [.function(name: "read", description: "Inspect", parameters: .object([:]))])
    let captured = Mutex<JSONValue?>(nil)
    try await withDependencies {
      $0.continuousClock = ContinuousClock()
      $0.date = DateGenerator { Date() }
      $0.fetch = FetchClient { request in
        let body = try? await request.body?.json(JSONValue.self)
        captured.withLock { $0 = body }
        return Response(status: .ok, body: .string(toolStepResponse(step: 9, signed: provider == .claude, model: provider.model)))
      }
    } operation: {
      _ = try await executor.run(attemptID: UUID(), lines: lines)
    }
    return try #require(captured.withLock { $0 })
  }

  private func notice(_ text: String) -> TranscriptItem {
    .notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init("context"), content: .init(text: "AGENTS.md fixture notice, \(text)")))
  }
}

private enum ProviderCatalogFixture {
  enum Provider: Equatable {
    case mimo, claude

    var id: String { self == .mimo ? "mimo" : "claude" }
    var model: String { self == .mimo ? "mimo-v2.6-pro" : "claude-test" }
  }

  static func document(_ provider: Provider) -> ModelsDocument {
    let entry = switch provider {
    case .mimo: #""dialect":"anthropic","baseURL":"https://api.xiaomimimo.com/anthropic","opaqueReplay":"affine""#
    case .claude: #""dialect":"anthropic","baseURL":"https://api.anthropic.com""#
    }
    return try! ModelsDocument(json: Data("""
    {"\(provider.id)":{\(entry),"models":{"\(provider.model)":{"maxInput":1048576,"maxOutput":65536,"efforts":["medium"],"defaultEffort":"medium"}}}}
    """.utf8))
  }

  static func catalog(_ document: ModelsDocument, account: String = "account") -> ProviderCatalog {
    ProviderCatalog(document: document, credentials: .bound { _ in .init(credential: .apiKey("fixture"), identityEpoch: account) }, oidcToken: { _, _ in "fixture" }, oidcBindingIdentity: { _, _ in account })
  }
}

private extension ModelsDocument {
  func merging(gateway: Provider?) -> ModelsDocument {
    var merged = self
    merged.providers["gateway"] = gateway
    return merged
  }
}

// Reconstructed SSE from dev.118's stored MiMo payloads (onion-pink-turkey, 0:2/0:6/0:10): thinking first, empty opaque, then two calls. No raw SSE was recorded. Claude's shape adds a signature.
private func toolStepResponse(step: Int, signed: Bool, model: String) -> String {
  let signature = signed ? ",\"signature\":\"fixture-signature\"" : ""
  return """
  event: message_start
  data: {"type":"message_start","message":{"model":"\(model)","usage":{"input_tokens":1}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"Inspect the repository"\(signature)}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: content_block_start
  data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_\(step)_1","name":"read","input":{}}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":1}

  event: content_block_start
  data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"call_\(step)_2","name":"read","input":{}}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":2}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}

  event: message_stop
  data: {"type":"message_stop"}


  """
}
