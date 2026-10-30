import Credentials
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// A parked compaction is placed, and its prompt frozen, at the wake that
// starts the next generation: what changed in between is what that
// generation runs on.
@Suite(.deterministicDependencies) struct ParkedCompactionTests {
  @Test func theWakePlacesTheGenerationAndRendersItsPrompt() async throws {
    try await withSessionDeps {
      let requests = Mutex<[(authorization: String, body: String)]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.text() ?? ""
          let round = requests.withLock { $0.append((request.headers.sensitiveValues["authorization"] ?? "", body)); return $0.count }
          return Response(status: .ok, body: .bytes(Data((round == 1 ? parkingCall : finalAnswer).utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) })
        try await ModelGroupRouteTests().install(harness)
        _ = try await harness.space.fs(.shared).write("/AGENTS.md", Data("root before the park".utf8), ifMatch: nil)
        let created = try await harness.call("/v1/session", .object(["title": "Parks", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        try await harness.running {
          try await harness.deliver("wrap up", to: id)
          try await until("the park settles") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 1 }
          #expect(try await harness.store.generationState(id).generation == 0)

          _ = try await harness.space.fs(.shared).write("/AGENTS.md", Data("root edited while parked".utf8), ifMatch: nil)
          let reset = Date().addingTimeInterval(18000).timeIntervalSince1970
          harness.runtime.usage.record("testing", plan: nil, windows: [.init(name: "five_hour", usedPercent: 99, resetsAt: reset), .init(name: "seven_day", usedPercent: 99, resetsAt: nil)], at: Date())
          harness.runtime.usage.record("alternate", plan: nil, windows: [.init(name: "five_hour", usedPercent: 0, resetsAt: reset), .init(name: "seven_day", usedPercent: 0, resetsAt: nil)], at: Date())

          try await harness.deliver("the next thing", to: id)
          try await until("the wake runs the next generation") { try await harness.store.record(id).work == .noWork && requests.withLock { $0.count } == 2 }
        }
        let emitted = requests.withLock { $0 }
        #expect(emitted[0].authorization == "Bearer key-testing")
        #expect(emitted[0].body.contains("root before the park"))
        #expect(emitted[1].authorization == "Bearer key-alternate")
        #expect(emitted[1].body.contains("root edited while parked") && !emitted[1].body.contains("root before the park"))
        #expect(emitted[1].body.contains("parked summary") && emitted[1].body.contains("the next thing"))
        #expect(try await harness.store.generationState(id).generation == 1)
      }
    }
  }
}

private let parkingCall: String = {
  let call: JSONValue = [
    "type": "function_call", "call_id": "call_park", "name": "compact",
    "arguments": .string((["summary": "parked summary", "park": true] as JSONValue).jsonString()),
  ]
  let events: [JSONValue] = [
    ["type": "response.output_item.added", "item": call],
    ["type": "response.output_item.done", "item": call],
    ["type": "response.completed", "response": ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15]]],
  ]
  return events.map { "data: " + $0.jsonString() + "\n\n" }.joined()
}()

private let finalAnswer: String = {
  let message: JSONValue = ["type": "message", "id": "msg_1", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": "ok", "annotations": []]]]
  let events: [JSONValue] = [
    ["type": "response.output_item.done", "item": message],
    ["type": "response.completed", "response": ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 1, "total_tokens": 11]]],
  ]
  return events.map { "data: " + $0.jsonString() + "\n\n" }.joined()
}()
