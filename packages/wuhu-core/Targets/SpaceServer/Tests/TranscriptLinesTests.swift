import Dependencies
import DeterministicDependencies
import struct ExecutionOwner.LineDifferenceLog
import Fetch
import Foundation
import JSONValue
import struct LoopCore.InferenceRequest
import SessionDomain
import enum SpaceContract.SessionToolExecutor
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct TranscriptLinesTests {
  @Test func theCheckIsOffWithoutItsVariable() {
    #expect(lineDifferenceLog(environment: [:]) == nil)
    #expect(lineDifferenceLog(environment: ["WUHU_TRANSCRIPT_DIFF_LOG": ""]) == nil)
  }

  @Test func aToolTurnsRequestsMatchTheirLinesAndADifferenceIsLogged() async throws {
    try await withSessionDeps {
      let records = Mutex<[JSONValue]>([])
      let log = LineDifferenceLog { data in records.withLock { $0.append(JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null) } }
      let rounds = Mutex(0)
      try await withDependencies {
        $0.fetch = FetchClient { _ in
          let round = rounds.withLock { $0 += 1; return $0 }
          let call = [
            #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_query","call_id":"provider_call","name":"query","arguments":""}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_query","call_id":"provider_call","name":"query","arguments":"{\"sql\":\"SELECT 1 AS n\"}"}}"#,
          ]
          let completed = #"{"type":"response.completed","response":{"id":"r\#(round)","status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":2}}}"#
          let events = (round == 1 ? call : []) + [completed]
          return Response(status: .ok, body: .bytes(Data(events.map { "data: \($0)\n\n" }.joined().utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(
          assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) }, lineDifferences: log,
        )
        let id = try await harness.createSession()
        try await harness.running {
          try await harness.deliver("query the constant", to: id)
          try await until("both requests answered") { try await harness.store.settledWork(id) && rounds.withLock { $0 } == 2 }
        }
        #expect(records.withLock { $0 }.isEmpty, "every request sent what its lines say")
        let keys = try await harness.store.lines(id, generation: 0).map(\.key)
        #expect(keys.first == "system")
        #expect(keys.filter { $0.hasPrefix("attempt:") }.count == 2)
        #expect(keys.contains { $0.hasPrefix("call:") })

        let transcript = try await harness.store.transcript(id)
        let request = InferenceRequest(sessionID: id, attemptID: UUID(), generation: 0, transcript: transcript, mode: .normal)
        await checkLines(log, store: harness.store, request: request, preamble: .init(system: "another prompt", tools: SessionToolExecutor.kernel.tools), at: Date())
        let planted = try #require(records.withLock { $0 }.first?.object)
        #expect(records.withLock { $0.count } == 1)
        #expect(planted["session"]?.stringValue == id.rawValue)
        #expect(planted["generation"]?.intValue == 0 && planted["position"]?.intValue == 0)
        let line = try #require(planted["line"]?.object?["hash"]?.stringValue)
        let render = try #require(planted["render"]?.object?["hash"]?.stringValue)
        #expect(line != render)
      }
    }
  }
}
