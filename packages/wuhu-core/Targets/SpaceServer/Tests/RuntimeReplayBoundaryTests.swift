import Credentials
import Dependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import SessionDomain
import struct SpaceContract.SessionCreateOutput
@testable import SpaceServer
import Synchronization
import Testing

@Suite struct RuntimeReplayBoundaryTests {
  @Test(arguments: [false, true]) func freshUnverifiedOIDCJWTPerResolutionStillReachesModelWithoutBoundaryLoop(alternatingSessions: Bool) async throws {
    try await withSessionDeps {
      let mints = Mutex(0)
      let requests = Mutex(0)
      try await withDependencies {
        $0.fetch = FetchClient { _ in
          requests.withLock { $0 += 1 }
          let event = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"done\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
          return Response(status: .ok, body: .bytes(Data(event.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\", \"auth\": \"oidc\"")
        let harness = try await SessionHarness(assembledModels: models, oidcToken: { _, session in
          let nonce = mints.withLock { $0 += 1; return $0 }
          let payload = Data("{\"iss\":\"issuer\",\"sub\":\"\(session.rawValue)\",\"aud\":\"audience\",\"jti\":\"nonce-\(nonce)\",\"iat\":\(nonce)}".utf8).base64EncodedString()
          return "header.\(payload).signature"
        })
        let first = try await harness.createSession()
        let second = alternatingSessions ? try await harness.createSession() : first
        try await harness.running {
          for round in 1 ... 4 {
            let id = round.isMultiple(of: 2) ? second : first
            try await harness.deliver("oidc input \(round)", to: id)
            try await until("unverified OIDC request committed") {
              guard requests.withLock({ $0 }) == round else { return false }
              return try await harness.store.record(id).work == .noWork
            }
            #expect(try await harness.store.generationState(id).generation == 0)
          }
        }
        #expect(mints.withLock { $0 } == 4)
      }
    }
  }

  @Test(arguments: [false, true]) func refreshReplaysButIdentityReplacementCompactsBeforeActualRequest(groupTarget: Bool) async throws {
    try await withSessionDeps {
      let held = Mutex(CredentialBinding(credential: .apiKey("access-a"), identityEpoch: "account-a"))
      let bodies = Mutex<[String]>([])
      try await withDependencies {
        $0.fetch = FetchClient { request in
          let body = try await request.body?.text() ?? ""
          let round = bodies.withLock { $0.append(body); return $0.count }
          let suffix = round == 3 ? "b" : "a"
          let events = [
            "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_\(suffix)\",\"summary\":[],\"encrypted_content\":\"opaque-\(suffix)\"}}",
            "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_\(suffix)\",\"summary\":[],\"encrypted_content\":\"opaque-\(suffix)\"}}",
            "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_\(round)\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}",
          ].map { "data: \($0)\n\n" }.joined(separator: "")
          return Response(status: .ok, body: .bytes(Data(events.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
        let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { _ in held.withLock { $0 } })
        let id: SessionID
        if groupTarget {
          let group = ModelsDocument.Group(members: [.init(id: "account", provider: "testing", model: "test-model")], defaultEffort: "high", policy: .quotaAware())
          _ = try await harness.space.fs(.shared).write(ModelsDocument.groupPath, JSONEncoder().encode(["work": group]), ifMatch: nil)
          let created = try await harness.call("/v1/session", .object(["title": "Group replay", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
          id = SessionID(created.id)
        } else {
          id = try await harness.createSession()
        }
        let initialRoute = try await harness.store.modelRoute(id)
        try await harness.running {
          for round in 0 ..< 3 {
            if round == 1 { held.withLock { $0.credential = .apiKey("refreshed-access-a") } }
            if round == 2 { held.withLock { $0 = .init(credential: .apiKey("access-b"), identityEpoch: "account-b") } }
            try await harness.deliver("input-\(round)", to: id)
            try await until("bound runtime request committed") {
              guard bodies.withLock({ $0.count }) == round + 1 else { return false }
              return try await harness.store.record(id).work == .noWork
            }
            #expect(try await harness.store.generationState(id).generation == (round == 2 ? 1 : 0))
            let route = try #require(await harness.store.modelRoute(id))
            if groupTarget { #expect(route == initialRoute) }
            let transcript = try await harness.store.transcript(id)
            if round < 2 { #expect(transcript.replayBinding?.epoch == route.epoch) }
            else { #expect(transcript.replayBinding?.epoch != route.epoch) }
          }
        }
        let emitted = bodies.withLock { $0 }
        #expect(emitted.count == 3)
        #expect(emitted[1].contains("opaque-a"))
        #expect(emitted[1].contains("rs_a"))
        #expect(!emitted[2].contains("opaque-a"))
        #expect(!emitted[2].contains("rs_a"))
        #expect(emitted[2].contains("Portable replay handoff completed"))
        #expect(emitted[2].contains("input-2"))
        #expect(try await harness.store.transcript(id).replayBinding?.epoch != "0")
      }
    }
  }
}
