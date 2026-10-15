import Dependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
@testable import SpaceServer
import Synchronization
import Testing

@Suite struct RuntimePortableThinkingTests {
  @Test func upgradeMidToolLoopCompletesAndNextMessageRestoresThinking() async throws {
    try await runUpgrade(wake: nil)
  }

  @Test(arguments: [SystemNotification.Kind.timer, .spaceObservation, .context])
  func upgradeMidToolLoopCompletesAndNotificationWakeRestoresThinking(kind: SystemNotification.Kind) async throws {
    try await runUpgrade(wake: kind)
  }

  private func runUpgrade(wake: SystemNotification.Kind?) async throws {
    try await withSessionDeps {
      let bodies = Mutex<[JSONValue]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.json(JSONValue.self) ?? .null
          let round = bodies.withLock { $0.append(body); return $0.count }
          var events: [(String, String)] = [("message_start", #"{"message":{"usage":{"input_tokens":10}}}"#)]
          if !round.isMultiple(of: 2) {
            if round > 2, body.object?["thinking"] != nil {
              events += [
                ("content_block_start", #"{"index":0,"content_block":{"type":"thinking","thinking":"reason","signature":"fresh-signature"}}"#),
                ("content_block_stop", #"{"index":0}"#),
              ]
            }
            events += [
              ("content_block_start", #"{"index":1,"content_block":{"type":"tool_use","id":"reply_call","name":"send_message","input":{"message":"done"}}}"#),
              ("content_block_stop", #"{"index":1}"#),
              ("message_delta", #"{"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#),
            ]
          } else {
            events += [
              ("content_block_start", #"{"index":0,"content_block":{"type":"text","text":""}}"#),
              ("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":"settled"}}"#),
              ("content_block_stop", #"{"index":0}"#),
              ("message_delta", #"{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#),
            ]
          }
          events.append(("message_stop", "{}"))
          let sse = events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
          return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = wake == .context ? testModelsJSON.replacingOccurrences(of: "\"maxInput\": 100000,", with: "\"cacheWarming\": {}, \"maxInput\": 100000,") : testModelsJSON
        let harness = try await SessionHarness(assembledModels: models)
        let id = try await harness.createSession()
        var source = try await harness.store.transcript(id)
        let items = thinkingHistory(binding: nil, scope: nil)
        source.items += items
        try await harness.store.append(id, items: items, transcript: source)
        try await harness.running {
          try await until("legacy turn completes without error") {
            let record = try await harness.store.record(id)
            try #require(record.work != .errored, "\(record.errorMessage ?? "")")
            return record.work == .noWork && bodies.withLock { $0.count } == 2
          }
          #expect(try await harness.store.generationState(id).generation == 1)
          if let wake {
            _ = try await harness.runtime.service.enqueue(item: .notification(.init(id: UUID(), timestamp: Date(), kind: wake, subscriptionID: .init(wake == .context ? "cache-warming" : "wake-trigger"), content: .init(text: "fresh notification turn"))), to: id)
          } else {
            try await harness.deliver("fresh user turn", to: id)
          }
          try await until("fresh turn completes with reasoning restored") {
            let record = try await harness.store.record(id)
            try #require(record.work != .errored, "\(record.errorMessage ?? "")")
            return record.work == .noWork && bodies.withLock { $0.count } == 4
          }
        }
        let emitted = bodies.withLock { $0 }
        #expect(emitted.count == 4)
        #expect(emitted.prefix(2).allSatisfy { $0.object?["thinking"] == nil })
        #expect(emitted.suffix(2).allSatisfy { $0.object?["thinking"]?.object?["type"]?.stringValue == "adaptive" })
        #expect(emitted.allSatisfy { !$0.jsonString().contains("OLD_SIGNATURE") })
        #expect(emitted.allSatisfy { $0.object?["model"]?.stringValue == "test-model" })
        #expect(try await harness.store.record(id).errorMessage == nil)
      }
    }
  }
}
