import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import Synchronization
import Testing
import WuhuAI

@Suite struct SocketObserverTests {
  @Test(arguments: ["valid", "malformed", "binary"])
  func receivedByteCountUsesWireBytesIncludingMalformedEvents(kind: String) async throws {
    let text = #"{ "type" : "response.completed", "response" : { "id" : "resp_ok", "status" : "completed", "usage" : { "input_tokens" : 1, "output_tokens" : 0 }, "output" : [] } }"#
    let malformed = "{ \"bad-JSON\":\n"
    let payload: WebSocketMessage = kind == "valid" ? .text(text) : (kind == "binary" ? .binary([1, 2, 3, 4]) : .text(malformed))
    let sizes = TrafficSizes()
    let session = ResponsesWebSocketSession()
    let observer = try socketAttemptObserver(file: nil, sizes: sizes)
    try await withDependencies { values in
      values[WebSocketConnector.self] = .init { _ in
        let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
        return WebSocketConnection(inbound: .init(events.stream), send: { _ in events.continuation.yield(.message(payload)) }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
      }
    } operation: {
      let inference = OpenAIGPTEndpoint(model: "test", apiKey: "offline").withWebSocket(session: session, attemptID: "one", observer: observer).inference(context: .init(messages: []))
      if kind == "valid" { _ = try await inference.collect() }
      else { await #expect(throws: InferenceError.self) { try await inference.collect() } }
    }
    #expect(sizes.response == (kind == "valid" ? text.utf8.count : (kind == "binary" ? 4 : malformed.utf8.count)))
    await session.invalidate()
  }

  @Test(arguments: [false, true])
  func onConnectAndIdleQuotaReachSessionReceiverWithoutFinishedAttemptTap(reconnect: Bool) async throws {
    let socket = QuotaObserverSocket(reconnect: reconnect)
    let session = ResponsesWebSocketSession()
    let notifications = AsyncStream<Void>.makeStream()
    let calls = Mutex(0)
    let tapped = Mutex(0)
    let endpoint = OpenAICodexEndpoint(model: "test", jwt: "offline", sessionID: "one", receiveResponseHeaders: { _ in
      for await _ in notifications.stream { break }
    })
    try await withDependencies { $0[WebSocketConnector.self] = socket.connector } operation: {
      _ = try await endpoint.withWebSocket(session: session, attemptID: "one", observer: .init(event: { _, _ in tapped.withLock { $0 += 1 } }), receiveQuota: { _ in
        calls.withLock { $0 += 1 }
        notifications.continuation.yield(())
      }).inference(context: .init(messages: [])).collect()
      #expect(calls.withLock { $0 } == (reconnect ? 2 : 1))
      await socket.quota()
      for await _ in notifications.stream { break }
      #expect(calls.withLock { $0 } == (reconnect ? 3 : 2))
      #expect(tapped.withLock { $0 } == (reconnect ? 2 : 1))
    }
    await session.invalidate()
  }

  @Test func correctiveReconnectMustKeepThisCallsQuotaReceiver() async throws {
    let calls = Mutex(0)
    let dials = Mutex(0)
    let session = ResponsesWebSocketSession()
    try await withDependencies { values in
      values[WebSocketConnector.self] = .init { _ in
        let number = dials.withLock { $0 += 1; return $0 }
        let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
        return WebSocketConnection(inbound: .init(events.stream), send: { _ in
          events.continuation.yield(.message(.text(#"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":1,"window_minutes":300,"reset_at":1800000000}}}"#)))
          let terminal = number == 1 ? #"{"type":"error","error":{"code":"websocket_connection_limit_reached","message":"expired"}}"# : #"{"type":"response.completed","response":{"id":"resp_ok","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#
          events.continuation.yield(.message(.text(terminal)))
        }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
      }
    } operation: {
      _ = try await OpenAIGPTEndpoint(model: "test", apiKey: "offline").withWebSocket(session: session, attemptID: "one", receiveQuota: { _ in calls.withLock { $0 += 1 } }).inference(context: .init(messages: [])).collect()
    }
    #expect(dials.withLock { $0 } == 2)
    #expect(calls.withLock { $0 } == 2)
    await session.invalidate()
  }

  @Test func rotatedCredentialMustKeepThisCallsQuotaReceiver() async throws {
    let calls = Mutex(0)
    let session = ResponsesWebSocketSession()
    try await withDependencies { values in
      values[WebSocketConnector.self] = .init { _ in
        let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
        return WebSocketConnection(inbound: .init(events.stream), send: { _ in
          events.continuation.yield(.message(.text(#"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":1,"window_minutes":300,"reset_at":1800000000}}}"#)))
          events.continuation.yield(.message(.text(#"{"type":"response.completed","response":{"id":"resp_ok","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#)))
        }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
      }
    } operation: {
      for key in ["credential-a", "credential-b"] {
        _ = try await OpenAIGPTEndpoint(model: "test", apiKey: key).withWebSocket(session: session, attemptID: key, receiveQuota: { _ in calls.withLock { $0 += 1 } }).inference(context: .init(messages: [])).collect()
      }
    }
    #expect(calls.withLock { $0 } == 2)
    await session.invalidate()
  }
}

private actor QuotaObserverSocket {
  private let reconnect: Bool
  private var connections = 0
  init(reconnect: Bool) { self.reconnect = reconnect }
  private var events: AsyncThrowingStream<WebSocketEvent, any Error>.Continuation?
  nonisolated var connector: WebSocketConnector { .init { _ in await self.connect() } }

  func connect() -> WebSocketConnection {
    connections += 1
    let expired = reconnect && connections == 1
    let pair = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
    events = pair.continuation
    quota()
    return WebSocketConnection(inbound: .init(pair.stream), send: { _ in
      let text = expired ? #"{"type":"error","error":{"code":"websocket_connection_limit_reached"}}"# : #"{"type":"response.completed","response":{"id":"resp_ok","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#
      pair.continuation.yield(.message(.text(text)))
    }, close: { _ in pair.continuation.finish() }, abort: { pair.continuation.finish() })
  }

  func quota() {
    events?.yield(.message(.text(#"{"type":"codex.rate_limits","rate_limits":{"primary":{"used_percent":1,"window_minutes":300,"reset_at":1800000000}}}"#)))
  }
}
