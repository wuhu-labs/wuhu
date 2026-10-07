import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Serve
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ResponsesServePairTests {
  @Test func serverEnforcesResponseAndCallReferencesAcrossACommittedToolTurn() async throws {
    let (client, server) = WebSocket.pair()
    let session = ResponsesWebSocketSession()
    let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    let connector = WebSocketConnector { _ in
      WebSocketConnection(inbound: .init(events.stream), send: { message in
        switch message {
        case .text(let text): try await client.send(.text(text))
        case .binary(let bytes): try await client.send(.binary(bytes))
        }
      }, close: { _ in client.close() }, abort: { client.abort() })
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await message in client.inbound {
          switch message {
          case .text(let text): events.continuation.yield(.message(.text(text)))
          case .binary(let bytes): events.continuation.yield(.message(.binary(bytes)))
          }
        }
        events.continuation.finish()
      }
      group.addTask {
        var turn = 0
        for await message in server.inbound {
          guard case let .text(text) = message, let body = JSONValue.parse(text)?.object else { throw PairFailure() }
          #expect(body["type"]?.stringValue == "response.create")
          if turn == 0 {
            #expect(body["previous_response_id"] == nil)
            for event in [
              #"{"type":"response.created","response":{"id":"resp_server"}}"#,
              #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_server","call_id":"call_server","name":"lookup","arguments":""}}"#,
              #"{"type":"response.function_call_arguments.done","item_id":"fc_server","arguments":"{\"key\":1}"}"#,
              #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_server","call_id":"call_server","name":"lookup","arguments":"{\"key\":1}"}}"#,
              #"{"type":"response.completed","response":{"id":"resp_server","status":"completed","usage":{"input_tokens":1,"output_tokens":1},"output":[]}}"#,
            ] { try await server.send(.text(event)) }
          } else {
            #expect(turn == 1)
            let input = try #require(body["input"]?.array)
            #expect(body["previous_response_id"]?.stringValue == "resp_server")
            #expect(input.count == 1)
            #expect(input[0].object?["type"]?.stringValue == "function_call_output")
            #expect(input[0].object?["call_id"]?.stringValue == "call_server")
            try await server.send(.text(#"{"type":"response.completed","response":{"id":"resp_after_tool","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#))
          }
          turn += 1
        }
        #expect(turn == 2)
      }
      do {
        try await withDependencies { $0[WebSocketConnector.self] = connector } operation: {
          let endpoint = OpenAIGPTEndpoint(model: "test", apiKey: "offline")
          var context = Context(messages: [.user(UserMessage(content: [.text(TextContent(text: "use lookup"))]))])
          var committed = try await endpoint.withWebSocket(session: session, attemptID: "one").inference(context: context).collect()
          if case var .toolCall(call) = committed.content[0] { call.id = "kernel_server_call"; committed.content[0] = .toolCall(call) }
          context.messages.append(.assistant(committed))
          await session.acknowledge(attemptID: "one", committedMessage: committed, toolCallIDs: ["call_server": "kernel_server_call"], renderedContext: context)
          context.messages.append(.toolResult(ToolResultMessage(toolCallId: "kernel_server_call", content: [.text(TextContent(text: "found"))])))
          _ = try await endpoint.withWebSocket(session: session, attemptID: "two").inference(context: context).collect()
        }
        await session.invalidate()
        client.abort()
        try await group.waitForAll()
      } catch {
        await session.invalidate()
        client.abort()
        group.cancelAll()
        throw error
      }
    }
  }
}

private struct PairFailure: Error {}
