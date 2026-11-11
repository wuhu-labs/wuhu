import Dependencies
import DeterministicDependencies
import struct ExecutionOwner.LineDifferenceLog
import Fetch
import Foundation
import JSONValue
import struct LoopCore.InferenceRequest
import SessionDomain
import struct SpaceContract.PromptSession
import struct SpaceCore.PendingPrompt
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct TranscriptLinesTests {
  @Test func theCheckIsOffWithoutItsVariable() {
    #expect(lineDifferenceLog(environment: [:]) == nil)
    #expect(lineDifferenceLog(environment: ["WUHU_TRANSCRIPT_DIFF_LOG": ""]) == nil)
  }

  @Test func aRequestSendsTheGenerationsStoredPromptAndToolsAndTheSessionIsToldOnceOfTheBinarysOwn() async throws {
    try await withSessionDeps {
      let sent = Mutex<[JSONValue]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = JSONValue.parse(String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)) ?? .null
          sent.withLock { $0.append(body) }
          let completed = #"{"type":"response.completed","response":{"id":"r","status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":2}}}"#
          return Response(status: .ok, body: .bytes(Data("data: \(completed)\n\n".utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(
          assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) },
        )
        let id = try await harness.createSession()
        guard case let .pending(pending) = try await harness.store.activatePrompt(id) else { Issue.record("expected a pending prompt"); return }
        let older = Tool(name: "only", description: "the one tool an older binary had", parameters: .object(["type": "object"]))
        _ = try await harness.store.storePrompt(id, for: pending, "rendered by an older binary", tools: [older], session: PromptSession(try await harness.store.record(id)))
        try await harness.running {
          try await harness.deliver("hello", to: id)
          try await until("the request answered") { try await harness.store.settledWork(id) && !sent.withLock { $0 }.isEmpty }
          try await harness.deliver("again", to: id)
          try await until("the second request answered") { try await harness.store.settledWork(id) && sent.withLock { $0 }.count == 2 }
        }
        for body in sent.withLock({ $0 }) {
          let request = try #require(body.object)
          let text = try body.jsonString()
          #expect(text.contains("rendered by an older binary"))
          #expect(text.contains("The server was upgraded and its tools differ") && text.contains("Removed: only."), "the notice comes before the first request")
          guard case let .array(tools)? = request["tools"] else { Issue.record("the request names no tools"); return }
          #expect(tools.map { $0.object?["name"]?.stringValue } == ["only"])
        }
        let notices = try await harness.store.transcript(id).items.filter { item in
          if case let .notification(notification) = item { notification.subscriptionID.rawValue == "tool-roster" } else { false }
        }
        #expect(notices.count == 1, "one notice for one binary")
      }
    }
  }

  @Test func aRequestOpensWithTheGroupsInstructionsThenTheSessionsOwn() async throws {
    try await withSessionDeps {
      let sent = Mutex<[JSONValue]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = JSONValue.parse(String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)) ?? .null
          sent.withLock { $0.append(body) }
          let completed = #"{"type":"response.completed","response":{"id":"r","status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":2}}}"#
          return Response(status: .ok, body: .bytes(Data("data: \(completed)\n\n".utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(
          assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) },
        )
        _ = try await harness.space.fs(.shared).write("/AGENTS.md", Data("house rules".utf8), ifMatch: nil)
        let id = try await harness.createSession()
        try await harness.running {
          try await harness.deliver("hello", to: id)
          try await until("the request answered") { try await harness.store.settledWork(id) && !sent.withLock { $0 }.isEmpty }
        }
        guard case let .array(input)? = sent.withLock({ $0 }).first?.object?["input"] else { Issue.record("the request has no input"); return }
        let items = try input.map { try $0.jsonString() }
        #expect(items.count >= 4)
        #expect(items[0].contains("Working in a Wuhu space") && !items[0].contains("house rules") && !items[0].contains(id.rawValue), "the system text is the binary's alone")
        #expect(items[1].contains("<group-instructions>") && items[1].contains("house rules") && items[1].contains(#""role":"user""#))
        #expect(items[2].contains("<session-instructions>") && items[2].contains("Your session id is \(id.rawValue)") && items[2].contains(#""role":"user""#))
        #expect(!items[3...].contains { $0.contains("-instructions>") })
        #expect(try await harness.store.lines(id, generation: 0).prefix(3).map(\.key) == ["system", "group", "session"])
      }
    }
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
        await checkLines(log, store: harness.store, request: request, rendered: "another", at: Date())
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
