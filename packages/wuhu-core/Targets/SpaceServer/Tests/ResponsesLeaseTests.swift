import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ResponsesLeaseTests {
  @Test(arguments: [Optional(401), Optional(409), nil])
  func providerFailureOrCancellationReleasesRegistryLeaseForResume(status: Int?) async throws {
    try await withSessionDeps {
      let creates = LeaseCreateCounter()
      try await withDependencies {
        $0[WebSocketConnector.self] = .init { _ in
          let events = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
          return WebSocketConnection(inbound: .init(events.stream), send: { _ in
            let count = creates.increment()
            if count == 1 {
              if let status { events.continuation.yield(.message(.text("{\"type\":\"error\",\"status\":\(status),\"error\":{\"code\":\"conflict\",\"message\":\"temporary conflict\"}}"))) }
            } else {
              events.continuation.yield(.message(.text(#"{"type":"response.completed","response":{"id":"resp_ok","status":"completed","usage":{"input_tokens":1,"output_tokens":0},"output":[]}}"#)))
            }
          }, close: { _ in events.continuation.finish() }, abort: { events.continuation.finish() })
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\",", with: "\"dialect\": \"responses\", \"transport\": \"websocket\",")
        let harness = try await SessionHarness(assembledModels: models)
        let sid = try await harness.createSession()
        try await harness.running {
          try await harness.deliver("hello", to: sid)
          if status == nil {
            try await until("pending provider request") { creates.value == 1 }
            try await harness.runtime.service.interrupt(sid)
            try await until("durable interruption") { try await harness.store.record(sid).hold == .interrupted }
          } else {
            try await until("provider failure") { try await harness.store.record(sid).work == .errored }
          }
          #expect(creates.value == 1)
          try await harness.runtime.service.resume(sid)
          try await until("resumed result") { let work = try await harness.store.record(sid).work; return work == .errored || work == .noWork }
          #expect(creates.value == 2)
          #expect(try await harness.store.record(sid).work == .noWork)
        }
      }
    }
  }
}

import Synchronization

private final class LeaseCreateCounter: Sendable {
  private let count = Mutex(0)
  func increment() -> Int { count.withLock { $0 += 1; return $0 } }
  var value: Int { count.withLock { $0 } }
}
