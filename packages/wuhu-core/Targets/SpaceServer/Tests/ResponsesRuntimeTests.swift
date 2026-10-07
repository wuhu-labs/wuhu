import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
@testable import SpaceServer
import Testing

@Suite(.timeLimit(.minutes(1))) struct ResponsesRuntimeTests {
  @Test func assembledRuntimeReleasesSuccessfulLeasesAcknowledgesActualCommitsAndRoutesQuota() async throws {
    try await withSessionDeps {
      let peer = RuntimeResponsesPeer()
      try await withDependencies { $0[WebSocketConnector.self] = peer.connector } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\",", with: "\"dialect\": \"responses\", \"transport\": \"websocket\",")
        let harness = try await SessionHarness(assembledModels: models)
        let sid = try await harness.createSession()
        try await harness.running {
          try await harness.deliver("query the constant", to: sid)
          try await until("two assembled WebSocket creates") { await peer.creates.count == 2 }
          try await until("assembled runtime settled") { try await harness.store.record(sid).work == .noWork }
          try await until("quota in production UsageBoard") { harness.runtime.usage.usage("testing")?.windows.first?.usedPercent == 22 }
          let usage = try #require(harness.runtime.usage.usage("testing"))
          #expect(usage.plan == "pro")
          #expect(usage.windows.first?.name == "five_hour")
          #expect(usage.windows.first?.resetsAt == 1_800_000_000)
          let creates = await peer.creates
          let continuation = try #require(creates.last?.object)
          #expect(continuation["previous_response_id"]?.stringValue == "resp_tool")
          let input = try #require(continuation["input"]?.array)
          #expect(input.count == 1)
          #expect(input[0].object?["type"]?.stringValue == "function_call_output")
          #expect(input[0].object?["call_id"]?.stringValue == "provider_call")
          #expect(await peer.dials == 1)
          guard case .kernel(let transcript) = try await harness.store.hydrate(sid).transcript else { Issue.record("expected kernel transcript"); return }
          let entries = transcript.items.compactMap { item -> AssistantEntry? in if case .assistant(let entry) = item { return entry }; return nil }
          #expect(entries.count == 2)
          let committedID = try #require(entries.first?.toolCallIDs["provider_call"])
          #expect(committedID.rawValue != "provider_call")
          #expect(transcript.items.contains { item in if case .toolResult(let result) = item, case .toolCall(let id) = result.provenance { return id == committedID }; return false })
        }
      }
    }
  }
}

private actor RuntimeResponsesPeer {
  var creates: [JSONValue] = []
  var dials = 0
  nonisolated var connector: WebSocketConnector { .init { _ in await self.connect() } }

  func connect() -> WebSocketConnection {
    dials += 1
    let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    events.continuation.yield(.message(.text(quota(7))))
    return WebSocketConnection(inbound: .init(events.stream), send: { message in try await self.send(message, into: events.continuation) }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
  }

  func send(_ message: WebSocketMessage, into events: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation) throws {
    guard case .text(let text) = message, let body = JSONValue.parse(text) else { throw WebSocketError.protocolViolation("unexpected create") }
    creates.append(body)
    let replies: [String]
    if creates.count == 1 {
      replies = [
        quota(11),
        #"{"type":"response.created","response":{"id":"resp_tool"}}"#,
        #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_query","call_id":"provider_call","name":"query","arguments":""}}"#,
        #"{"type":"response.function_call_arguments.done","item_id":"fc_query","arguments":"{\"sql\":\"SELECT 1 AS n\"}"}"#,
        #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_query","call_id":"provider_call","name":"query","arguments":"{\"sql\":\"SELECT 1 AS n\"}"}}"#,
        #"{"type":"response.completed","response":{"id":"resp_tool","status":"completed","usage":{"input_tokens":1,"output_tokens":1},"output":[]}}"#,
      ]
    } else {
      replies = [#"{"type":"response.completed","response":{"id":"resp_done","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#, quota(22)]
    }
    for reply in replies { events.yield(.message(.text(reply))) }
  }

  private func quota(_ percent: Int) -> String {
    "{\"type\":\"codex.rate_limits\",\"plan_type\":\"pro\",\"rate_limits\":{\"primary\":{\"used_percent\":\(percent),\"window_minutes\":300,\"reset_at\":1800000000}}}"
  }
}
