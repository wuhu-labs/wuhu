import ControlledTime
import Dependencies
import DeterministicDependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite(.deterministicDependencies(clock: VirtualClock())) struct LineContextTests {
  @Test func acknowledgementUsesTheCompletedRequestContextAndKernelCallMapping() async throws {
    let server = ContextSocket()
    let socket = ResponsesWebSocketSession()
    let model = ResolvedModel(specifier: .init(provider: "offline", model: "test", effort: "low"), endpoint: OpenAIGPTEndpoint(model: "test", replayScope: "fixture-scope", apiKey: "fixture"), budget: .init(maxInput: 10000, maxOutput: 100), transport: .websocket, replayScope: "fixture-scope")
    var executor = InferenceExecutor(session: .init("line-context"), model: model, systemPrompt: "offline", opening: ["frozen opening"], tools: [.function(name: "read", description: "read", parameters: .object([:]))], webSocket: socket)
    var lines = [TranscriptLine(at: Date(), key: "message:input", message: .user(.init(content: [.text("start")])))]
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      let attemptID = UUID(1)
      let completed = try await executor.run(attemptID: attemptID, lines: lines)
      let entry = AssistantEntry(completed.message, id: attemptID, at: Date(), metadata: completed.metadata, replayBinding: nil, mint: { ToolCallID("kernel-call") })
      #expect(entry.toolCallIDs == ["provider-call": ToolCallID("kernel-call")])
      executor.systemPrompt = "changed after request"
      executor.opening = ["changed after request"]
      await executor.acknowledge(entry: entry, context: completed.context)
      executor.systemPrompt = "offline"
      executor.opening = ["frozen opening"]
      lines += TranscriptItem.assistant(entry).lines(session: executor.session)
      lines += TranscriptItem.toolResult(.init(id: UUID(), timestamp: Date(), provenance: .toolCall(.init("kernel-call")), payload: .failure(.init(message: "receipt")))).lines(session: executor.session)
      _ = try await executor.run(attemptID: UUID(2), lines: lines)
    }
    let sent = await server.sent
    #expect(sent.count == 2)
    #expect(sent[1].object?["previous_response_id"] == .string("resp_1"))
    let delta = try #require(sent[1].object?["input"]?.array)
    #expect(delta.count == 1)
    #expect(delta[0].object?["call_id"] == .string("provider-call"))
    #expect(delta[0].object?["output"] == .string("receipt"))
    #expect(await server.dials == 1)
    await socket.invalidate()
  }
}

private actor ContextSocket {
  var sent: [JSONValue] = []
  var dials = 0

  nonisolated var connector: WebSocketConnector { .init { _ in await self.connect() } }

  func connect() -> WebSocketConnection {
    dials += 1
    let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    return WebSocketConnection(inbound: .init(events.stream), send: { message in await self.respond(message, into: events.continuation) }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
  }

  func respond(_ message: WebSocketMessage, into events: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation) {
    guard case let .text(text) = message, let body = JSONValue.parse(text) else { preconditionFailure("expected a response.create frame") }
    sent.append(body)
    let id = "resp_\(sent.count)"
    events.yield(.message(.text("{\"type\":\"response.created\",\"response\":{\"id\":\"\(id)\"}}")))
    if sent.count == 1 {
      let item = #"{"type":"function_call","id":"fc_1","call_id":"provider-call","name":"read","arguments":"{}"}"#
      events.yield(.message(.text(#"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"provider-call","name":"read","arguments":""}}"#)))
      events.yield(.message(.text(#"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{}"}"#)))
      events.yield(.message(.text("{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"arguments\":\"{}\"}")))
      events.yield(.message(.text("{\"type\":\"response.output_item.done\",\"item\":\(item)}")))
    }
    events.yield(.message(.text("{\"type\":\"response.completed\",\"response\":{\"id\":\"\(id)\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}")))
  }
}
