import Clocks
import Dependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// A script may interrupt its own session. The interrupt waits for the
// session's turn to end, the turn waits for the script's call, and the call
// waits for the script, which waits for the interrupt: the call's wind-down
// limit is what breaks the cycle.
@Suite struct ScriptSelfInterruptTests {
  @Test func aScriptThatInterruptsItsOwnSessionLeavesItInterruptedAndResumable() async throws {
    let clock = TestClock()
    let provider = ScriptedProvider()
    try await withDependencies {
      $0.date = DateGenerator { Date() }
      $0.uuid = UUIDGenerator { UUID() }
      $0.continuousClock = clock
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
      $0.fetch = provider.client
    } operation: {
      let harness = try await SessionHarness(assembledModels: responsesModels)
      let session = try await harness.createSession(title: "self", provider: "openai", model: "gpt-5.6-luna")
      provider.interrupting(session)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await harness.runtime.run() }
        defer { group.cancelAll() }
        try await harness.deliver("start-the-script", to: session)
        #expect(try await realPollUntil {
          await clock.advance(by: .seconds(1))
          return try await harness.store.record(session).hold == .interrupted
        }, "the interrupt returned")
        try await harness.deliver("sent-after-the-interrupt", to: session)
        try await harness.runtime.service.resume(session)
        #expect(try await realPollUntil {
          guard provider.saw("sent-after-the-interrupt") else { return false }
          return try await harness.store.record(session).work == .noWork
        }, "the message sent afterwards went in on resume")
      }
    }
  }
}

// Answers the request carrying the first delivery with a run_script call whose
// script interrupts the session, and every other with a short final answer.
private final class ScriptedProvider: Sendable {
  private let bodies = Mutex<[String]>([])
  private let session = Mutex<SessionID?>(nil)

  func interrupting(_ session: SessionID) {
    self.session.withLock { $0 = session }
  }

  func saw(_ text: String) -> Bool {
    bodies.withLock { $0.contains { $0.contains(text) } }
  }

  var client: FetchClient {
    FetchClient { request in
      let body = String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)
      self.bodies.withLock { $0.append(body) }
      var stream = finalAnswer
      if body.contains("start-the-script"), !body.contains("function_call_output"), let session = self.session.withLock({ $0 }) {
        stream = runScriptCall(interrupting: session)
      }
      return Response(status: .ok, headers: HTTPFields(), body: .bytes(Data(stream.utf8), contentType: "text/event-stream"))
    }
  }
}

private func runScriptCall(interrupting session: SessionID) -> String {
  let arguments: JSONValue = [
    "source": .string("""
    import { interrupt } from "wuhu:session"
    await interrupt("\(session.rawValue)")
    result("interrupted")
    """),
    "timeout_seconds": 1_000_000,
  ]
  let call: JSONValue = [
    "type": "function_call", "call_id": "call_1", "name": "run_script", "arguments": .string(arguments.jsonString()),
  ]
  let events: [JSONValue] = [
    ["type": "response.output_item.added", "item": call],
    ["type": "response.output_item.done", "item": call],
    ["type": "response.completed", "response": [
      "status": "completed",
      "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15],
    ]],
  ]
  return events.map { "data: " + $0.jsonString() + "\n\n" }.joined()
}

private let finalAnswer = """
event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"},"output_index":0,"sequence_number":1}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","model":"gpt-5.6-luna","output":[{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"}],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0},"output_tokens":1,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":11}},"sequence_number":2}


"""

private let responsesModels = """
{
  "openai": {
    "dialect": "responses",
    "baseURL": "https://api.openai.com/v1",
    "models": {
      "gpt-5.6-luna": {
        "maxInput": 400000,
        "maxOutput": 128000,
        "efforts": ["low", "medium", "high"],
        "defaultEffort": "medium"
      }
    }
  }
}
"""
