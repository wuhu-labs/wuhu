import Credentials
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import SessionDomain
import Synchronization
import Testing
import WuhuAI

@Suite struct UnsignedThinkingTests {
  @Test(arguments: [false, true])
  func optedInMiMoCompletesFourThinkingToolSteps(oidc: Bool) async throws {
    let bodies = try await toolLoop(acceptsUnsigned: true, signed: false, oidc: oidc)
    #expect(bodies.count == 4)
    let content = try #require(bodies.last?.object?["messages"]?.array?.last(where: { $0.object?["role"] == .string("assistant") })?.object?["content"]?.array)
    #expect(content.first?.object?["type"] == .string("thinking"))
    #expect(content.first?.object?["signature"] == nil)
  }

  @Test(arguments: [false, nil] as [Bool?])
  func strictEndpointRejectsUnsignedHistoryWhenNotMaskedByNotice(setting: Bool?) async throws {
    let bodies = try await toolLoop(acceptsUnsigned: setting, signed: false)
    #expect(bodies.count == 3, "Context notices mask the first two unsigned tool turns, but not the third")
  }

  @Test func signedClaudeHistorySurvivesParallelResultContextNotice() async throws {
    let bodies = try await toolLoop(acceptsUnsigned: nil, signed: true)
    #expect(bodies.count == 4)
    #expect(bodies.last?.jsonString().contains("fixture-signature") == true)
  }

  @Test func settingRoundTripsAndRejectsWrongTypes() throws {
    let document = try catalogDocument(acceptsUnsigned: true)
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
    let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
      .replacingOccurrences(of: "\"acceptsUnsignedThinking\":true", with: "\"acceptsUnsignedThinking\":\"true\"")
    #expect(throws: CatalogError.invalidDocument) { try ModelsDocument(json: Data(encoded.utf8)) }
  }

  @Test func settingRequiresAnthropicDialect() async throws {
    var document = try catalogDocument(acceptsUnsigned: true)
    document.providers["mimo"]?.dialect = .responses
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    #expect(throws: CatalogError.unsignedThinkingRequiresAnthropic(provider: "mimo")) {
      try catalog.validate(.init(provider: "mimo", model: "mimo-v2.6-pro", effort: "medium"))
    }
  }

  @Test func unsignedAcceptanceDoesNotEstablishAccountAffinity() throws {
    var document = try catalogDocument(acceptsUnsigned: true)
    document.providers["mimo"]?.opaqueReplay = .some(.none)
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    #expect(throws: CatalogError.opaqueReplayRequiresNoThinking(provider: "mimo", model: "mimo-v2.6-pro")) {
      try catalog.validate(.init(provider: "mimo", model: "mimo-v2.6-pro", effort: "medium"))
    }
  }

  @Test(arguments: [false, true])
  func deepSeekExplicitFalseOverridesLegacyUnsignedDefault(oidc: Bool) async throws {
    let document = try catalogDocument(acceptsUnsigned: false)
    var deepSeek = document
    deepSeek.providers["deepseek"] = deepSeek.providers.removeValue(forKey: "mimo")
    deepSeek.providers["deepseek"]?.auth = oidc ? .oidc : nil
    let model = try await catalog(deepSeek).resolve(.init(provider: "deepseek", model: "mimo-v2.6-pro", effort: "medium"), session: .init("fixture"))
    #expect((model.endpoint as? any AnthropicMessagesEndpoint)?.acceptsUnsignedThinking == false)
  }

  private func toolLoop(acceptsUnsigned: Bool?, signed: Bool, oidc: Bool = false) async throws -> [JSONValue] {
    var document = try catalogDocument(acceptsUnsigned: acceptsUnsigned)
    document.providers["mimo"]?.auth = oidc ? .oidc : nil
    let provider = signed ? "claude" : "mimo"
    let modelName = signed ? "claude-test" : "mimo-v2.6-pro"
    if signed {
      let stored = document.providers.removeValue(forKey: "mimo")
      var declaration = try #require(stored)
      declaration.dialect = .claude
      declaration.baseURL = URL(string: "https://api.anthropic.com")!
      declaration.models[modelName] = declaration.models.removeValue(forKey: "mimo-v2.6-pro")
      document.providers[provider] = declaration
    }
    let model = try await catalog(document).resolve(.init(provider: provider, model: modelName, effort: "medium"), session: .init("fixture"))
    let bodies = Mutex<[JSONValue]>([])
    var transcript = Transcript(items: [.direct(.init(id: UUID(), sender: .init(id: "owner", timeZone: TimeZone(identifier: "UTC")!), timestamp: Date(), content: .init(text: "Inspect using tools")))])
    let executor = InferenceExecutor(session: .init("fixture"), model: model, systemPrompt: "test", tools: [.function(name: "read", description: "Inspect", parameters: .object([:]))])
    try await withDependencies {
      $0.continuousClock = ContinuousClock()
      $0.date = DateGenerator { Date() }
      $0.fetch = FetchClient { request in
        let body = try #require(try await request.body?.json(JSONValue.self))
        #expect(body.object?["thinking"]?.object?["type"] == .string("adaptive"))
        let messages = try #require(body.object?["messages"]?.array)
        for (index, message) in messages.enumerated() where message.object?["role"] == .string("assistant") {
          let calls = message.object?["content"]?.array?.filter { $0.object?["type"] == .string("tool_use") } ?? []
          guard !calls.isEmpty else { continue }
          let results = try #require(messages[index + 1].object?["content"]?.array)
          #expect(calls.compactMap { $0.object?["id"] } == results.compactMap { $0.object?["tool_use_id"] })
        }
        let step = bodies.withLock { $0.append(body); return $0.count }
        return Response(status: .ok, body: .string(response(step: step, signed: signed)))
      }
    } operation: {
      for step in 1 ... 4 {
        if step == 4, acceptsUnsigned != true, !signed {
          await #expect(throws: InferenceError.invalidInput(status: 400, body: "Anthropic thinking tool history requires signed thinking; the current tool-use assistant history has missing, unsigned or incompatible thinking")) {
            try await executor.run(attemptID: UUID(), transcript: transcript, mode: .normal)
          }
          break
        }
        let completed = try await executor.run(attemptID: UUID(), transcript: transcript, mode: .normal)
        guard case let .reasoning(.encrypted(thinking))? = completed.message.content.first else {
          Issue.record("Missing recorded-shape thinking"); return
        }
        #expect(thinking.opaque == (signed ? "fixture-signature" : ""))
        #expect(thinking.replayScope == model.replayScope)
        #expect(thinking.providerID == "anthropic")
        let calls = completed.message.content.compactMap { block -> ToolCall? in
          guard case let .toolCall(call) = block else { return nil }
          return call
        }
        transcript.append(.assistant(.init(id: UUID(), timestamp: Date(), content: completed.message.content, stopReason: .stop, usage: completed.metadata.usage ?? .init(inputTokens: 0, outputTokens: 0, totalTokens: 0), toolCallIDs: Dictionary(uniqueKeysWithValues: calls.map { ($0.id, .init($0.id)) }), replayBinding: .init(identity: model.bindingIdentity, epoch: "route"))))
        for (index, call) in calls.enumerated() {
          transcript.append(.toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init(call.id)), payload: .failure(.init(message: "fixture receipt")))))
          if (step == 1 && index == 1) || (step == 2 && index == 0) {
            transcript.append(.notification(.init(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init("context"), content: .init(text: "AGENTS.md fixture notice"))))
          }
        }
      }
    }
    return bodies.withLock { $0 }
  }

  private func catalogDocument(acceptsUnsigned: Bool?) throws -> ModelsDocument {
    let flag = acceptsUnsigned.map { "\"acceptsUnsignedThinking\":\($0)," } ?? ""
    return try ModelsDocument(json: Data("""
    {"mimo":{"dialect":"anthropic","baseURL":"https://api.xiaomimimo.com/anthropic","opaqueReplay":"affine",\(flag)
      "models":{"mimo-v2.6-pro":{"maxInput":1048576,"maxOutput":65536,"efforts":["medium"],"defaultEffort":"medium"}}}}
    """.utf8))
  }

  private func catalog(_ document: ModelsDocument) -> ProviderCatalog {
    ProviderCatalog(document: document, credentials: .bound { _ in .init(credential: .apiKey("fixture"), identityEpoch: "account") }, oidcToken: { _, _ in "fixture" }, oidcBindingIdentity: { _, _ in "account" })
  }
}

// Reconstructed SSE from dev.118's stored MiMo payloads (onion-pink-turkey, 0:2/0:6/0:10): thinking first, empty opaque, then two calls. No raw SSE was recorded.
private func response(step: Int, signed: Bool) -> String {
  let model = signed ? "claude-test" : "mimo-v2.6-pro"
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
