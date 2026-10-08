import Dependencies
import Fetch
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct PressureReplayTests {
  @Test(arguments: ["responses", "anthropic", "chat"], [false, true])
  func sseReplayKeepsHistoricalNotice(dialect: String, image: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "SSE pressure", kind: .agent, createdBy: "morgan", model: .test)
      let endpoint: any ModelEndpoint
      switch dialect {
      case "responses": endpoint = OpenAIGPTEndpoint(model: "test", apiKey: "offline")
      case "anthropic": endpoint = AnthropicEndpoint(model: "test", apiKey: "offline")
      default: endpoint = ReplayChatEndpoint()
      }
      let model = ResolvedModel(specifier: .init(provider: "offline", model: "test", effort: "low"), endpoint: endpoint, budget: .init(maxInput: 1_001_000, maxOutput: 1000))
      let bodies = Box<[JSONValue]>([])
      let commits = Box(0)
      let fetch = FetchClient { request in
        let text = try await request.body?.text() ?? "null"
        let body = try #require(JSONValue.parse(text))
        bodies.withLock { $0.append(body) }
        let sse: String
        switch dialect {
        case "responses":
          sse = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":710000,\"output_tokens\":0}}}\n\n"
        case "anthropic":
          sse = "event: message_start\ndata: {\"message\":{\"usage\":{\"input_tokens\":710000}}}\n\nevent: message_delta\ndata: {\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":0}}\n\nevent: message_stop\ndata: {}\n\n"
        default:
          sse = "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":710000,\"completion_tokens\":0}}\n\ndata: [DONE]\n\n"
        }
        return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
      }
      let config = makeConfig(inference: { request in
        let executor = InferenceExecutor(session: sid, model: model, systemPrompt: "offline", tools: [], mediaResolver: { _ in ReplayImageResolver() })
        let completed = try await executor.run(attemptID: request.attemptID, transcript: request.transcript, mode: .normal)
        return InferenceReply(message: completed.message, metadata: completed.metadata, committed: { _, _ in commits.withLock { $0 += 1 } })
      })
      try await withDependencies { $0.fetch = fetch } operation: {
        try await runService(sessions, config) { service in
          for round in 0 ..< 3 {
            var input = Fix.message("round \(round)", message: "m\(round)")
            if image, round == 0, case var .message(message) = input {
              message.content.attachments = [.image(path: "/picture.png", mimeType: "image/png", size: 3)]
              input = .message(message)
            }
            _ = try await service.enqueue(item: input, to: sid)
            try await until("SSE commit") { commits.value == round + 1 }
            try await until("settled") { try await sessions.settledWork(sid) }
          }
        }
      }
      let key = dialect == "responses" ? "input" : "messages"
      let second = try #require(bodies.value[1].object?[key]?.array)
      let third = try #require(bodies.value[2].object?[key]?.array)
      #expect(second.last?.jsonString().contains("71% full") == true)
      #expect(third.prefix(second.count).map { $0.jsonString() } == second.map { $0.jsonString() })
      #expect(bodies.value.allSatisfy { $0.object?["previous_response_id"] == nil })
      if image { #expect(bodies.value[2].jsonString().contains("AQID")) }
    }
  }

  @Test(arguments: [false, true])
  func fullWarmPressureCommitAndReconnect(image: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "pressure replay", kind: .agent, createdBy: "morgan", model: .test)
      let registry = ResponsesSocketRegistry()
      let document = ModelsDocument(providers: ["offline": .init(dialect: .responses, baseURL: URL(string: "https://example.test/v1")!, transport: .websocket, models: ["test": .init(maxInput: 1_001_000, maxOutput: 1000, efforts: ["low"], defaultEffort: "low")])])
      let model = try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey("offline") }).resolve(.init(provider: "offline", model: "test", effort: "low"), session: sid)
      let bodies = Box<[JSONValue]>([])
      let commits = Box<[AssistantEntry]>([])
      let dials = Box(0)
      let connector = WebSocketConnector { _ in
        dials.withLock { $0 += 1 }
        let stream = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
        return WebSocketConnection(inbound: .init(stream.stream), send: { message in
          guard case let .text(text) = message, let body = JSONValue.parse(text) else { throw UnexpectedCall("binary create") }
          let turn = bodies.withLock { $0.append(body); return $0.count }
          let response = "resp_\(turn)"
          let events = turn < 4 ? [
            "{\"type\":\"response.created\",\"response\":{\"id\":\"\(response)\"}}",
            "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_\(turn)\",\"call_id\":\"call_\(turn)\",\"name\":\"lookup\",\"arguments\":\"\"}}",
            "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_\(turn)\",\"arguments\":\"{}\"}",
            "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_\(turn)\",\"call_id\":\"call_\(turn)\",\"name\":\"lookup\",\"arguments\":\"{}\"}}",
          ] : []
          for event in events + ["{\"type\":\"response.completed\",\"response\":{\"id\":\"\(response)\",\"status\":\"completed\",\"usage\":{\"input_tokens\":\(700_000 + turn * 10000),\"output_tokens\":0},\"output\":[]}}"] {
            stream.continuation.yield(.message(.text(event)))
          }
        }, close: { _ in stream.continuation.finish() }, abort: { stream.continuation.finish() })
      }
      var config = makeConfig(executeTool: { _ in .failure(.init(message: "lookup complete")) }, inference: { request in
        // The real notification is already durable before anything reaches the provider.
        #expect(try await sessions.hydrate(sid).transcript.kernel == request.transcript)
        let lease = try await registry.acquire(session: sid, model: model)
        let executor = InferenceExecutor(session: sid, model: model, systemPrompt: "offline", tools: [Tool(name: "lookup", description: "lookup", parameters: .object(["type": .string("object")]))], webSocket: lease.session, mediaResolver: { _ in ReplayImageResolver() })
        let completed = try await executor.run(attemptID: request.attemptID, transcript: request.transcript, mode: .normal)
        await registry.release(session: sid, lease: lease.lease)
        return InferenceReply(message: completed.message, metadata: completed.metadata, committed: { entry, transcript in
          let count = commits.withLock { $0.append(entry); return $0.count }
          await executor.acknowledge(entry: entry, transcript: transcript)
          if count == 3 { await registry.invalidate(sid) }
        })
      })
      config.invalidateInference = { await registry.invalidate($0) }
      try await withDependencies { $0[WebSocketConnector.self] = connector } operation: {
        try await runService(sessions, config) { service in
          var input = Fix.message("go")
          if image, case var .message(message) = input {
            message.content.attachments = [.image(path: "/picture.png", mimeType: "image/png", size: 3)]
            input = .message(message)
          }
          _ = try await service.enqueue(item: input, to: sid)
          try await until("four commits") { commits.value.count == 4 }
          try await until("settled") { try await sessions.settledWork(sid) }
        }
      }
      #expect(dials.value == 2)
      let requests = bodies.value
      #expect(requests.count == 4)
      #expect(requests[0].object?["previous_response_id"] == nil)
      #expect(requests[1].object?["previous_response_id"] == .string("resp_1"))
      #expect(requests[2].object?["previous_response_id"] == .string("resp_2"))
      #expect(requests[3].object?["previous_response_id"] == nil)
      let second = try #require(requests[1].object?["input"]?.array)
      #expect(second.last?.jsonString().contains("71% full") == true)
      let third = try #require(requests[2].object?["input"]?.array)
      #expect(third.last?.jsonString().contains("72% full") == true)
      var consumed = try #require(requests[0].object?["input"]?.array)
      for turn in 1 ... 3 {
        consumed.append(.object(["type": .string("function_call"), "call_id": .string("call_\(turn)"), "name": .string("lookup"), "arguments": .string("{}")]))
        if turn < 3 { consumed += try #require(requests[turn].object?["input"]?.array) }
      }
      let aliases = Dictionary(uniqueKeysWithValues: commits.value.flatMap { $0.toolCallIDs.map { ($0.value.rawValue, $0.key) } })
      let replay = try #require(requests[3].object?["input"]?.array).map { item -> JSONValue in
        guard var object = item.object, let id = object["call_id"]?.stringValue, let original = aliases[id] else { return item }
        object["call_id"] = .string(original)
        return .object(object)
      }
      // IDs are deliberately kernel-normalized on full creates; every other byte stays put.
      #expect(replay.prefix(consumed.count).map { $0.jsonString() } == consumed.map { $0.jsonString() })
      #expect(replay.last?.jsonString().contains("73% full") == true)
      if image { #expect(consumed.first { $0.jsonString().contains("data:image/png;base64,AQID") } != nil) }
      let persisted = try await sessions.hydrate(sid).transcript.kernel
      let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(persisted))
      let restored = await decoded.renderRequest(session: sid, systemPrompt: "offline")
      let original = await persisted.renderRequest(session: sid, systemPrompt: "offline")
      #expect(restored == original)
    }
  }
}

private struct ReplayImageResolver: MediaResolver {
  func resolve(_ media: MediaContent) async throws -> ResolvedMedia? { .data(Data([1, 2, 3]), mimeType: "image/png") }
}

private struct ReplayChatEndpoint: ChatCompletionsEndpoint {
  let providerID = "offline-chat"
  let model = "test"
  let baseURL = URL(string: "https://example.test/v1")!
}
