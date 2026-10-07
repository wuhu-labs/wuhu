import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import JSONValue
import Scratch
import SessionDomain
import Testing
import WuhuAI

@Suite struct SocketAttemptLogTests {
  @Test func correctiveCreatesStayInTheirLogicalAttemptAndReuseDoesNotRetainItsTap() async throws {
    let directory = try scratchURL("socket-attempt-log")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = LogSocket()
    let socket = ResponsesWebSocketSession()
    let model = ResolvedModel(specifier: .init(provider: "offline", model: "test", effort: "low"), endpoint: OpenAIGPTEndpoint(model: "test", apiKey: "do-not-log-credential"), budget: .init(maxInput: 10000, maxOutput: 100), transport: .websocket)
    let executor = InferenceExecutor(session: .init("one"), model: model, systemPrompt: "offline", tools: [], log: .init(directory: directory), webSocket: socket)
    try await withDependencies { $0[WebSocketConnector.self] = server.connector } operation: {
      _ = try await executor.run(attemptID: UUID(1), transcript: .init(), mode: .normal)
      let firstURL = directory.appendingPathComponent("\(UUID(1).uuidString.lowercased()).log")
      let first = try Data(contentsOf: firstURL)
      let firstText = String(decoding: first, as: UTF8.self)
      #expect(firstText.contains("[websocket request 1]"))
      #expect(firstText.contains("[websocket request 2]"))
      #expect(firstText.contains("websocket_connection_limit_reached"))
      #expect(firstText.contains("resp_2"))
      #expect(!firstText.contains("do-not-log-credential"))
      #expect(!firstText.contains("authorization"))
      _ = try await executor.run(attemptID: UUID(2), transcript: .init(), mode: .normal)
      #expect(try Data(contentsOf: firstURL) == first)
      let second = try String(contentsOf: directory.appendingPathComponent("\(UUID(2).uuidString.lowercased()).log"), encoding: .utf8)
      #expect(second.contains("resp_3"))
      #expect(!second.contains("resp_2"))
      #expect(!second.contains("[websocket request 2]"))
    }
    #expect(await server.dials == 2)
    await socket.invalidate()
  }
}

private actor LogSocket {
  var dials = 0
  var creates = 0
  nonisolated var connector: WebSocketConnector { .init { _ in await self.connect() } }

  func connect() -> WebSocketConnection {
    dials += 1
    let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    return WebSocketConnection(inbound: .init(events.stream), send: { _ in await self.respond(events.continuation) }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
  }

  func respond(_ events: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation) {
    creates += 1
    if creates == 1 {
      events.yield(.message(.text(#"{"type":"error","error":{"code":"websocket_connection_limit_reached","message":"expired"}}"#)))
    } else {
      events.yield(.message(.text("{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_\(creates)\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0},\"output\":[]}}")))
    }
  }
}
