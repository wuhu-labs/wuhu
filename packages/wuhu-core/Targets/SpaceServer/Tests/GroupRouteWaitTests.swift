import ControlledTime
import Credentials
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import LoopCore
import class MainHub.Hub
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WuhuAI

extension GroupSwitchingTests {
  @Test func nineConsecutiveOutagesWaitInsteadOfParkingAGroupSession() async throws {
    try await withSessionDeps {
      let failures = 9
      let requests = Mutex(0)
      let now = Mutex(Date())
      let clock = VirtualClock()
      try await withDependencies {
        $0.date = DateGenerator { now.withLock { $0 } }
        $0.continuousClock = clock
        $0.withRandomNumberGenerator = WithRandomNumberGenerator(NoJitter())
        $0.fetch = FetchClient { _ in
          let round = requests.withLock { $0 += 1; return $0 }
          return round <= failures ? Response(status: .serviceUnavailable, body: .string("down")) : completedResponse()
        }
      } operation: {
        let harness = try await responsesHarness()
        let created = try await harness.call("/v1/session", .object(["title": "Through an outage", "kind": "agent", "modelGroup": "work"]), as: SessionCreateOutput.self)
        let id = SessionID(created.id)
        try await harness.running {
          try await harness.deliver("request during an outage", to: id)
          try await until("the outage passed and the held member answered") {
            let work = try await harness.store.record(id).work
            // The retry's sleep is armed on the clock after the failure lands, which can be after the advance that made it due: keep the clock moving while a failure stands rather than only while its deadline is ahead.
            if let retry = try await harness.store.modelRoute(id)?.failure?.retryAt {
              now.withLock { $0 = max($0, retry).addingTimeInterval(1) }
              await clock.advance(by: .seconds(61))
            }
            #expect(work != .errored)
            return work == .noWork && requests.withLock { $0 } > failures
          }
        }
        let route = try #require(await harness.store.modelRoute(id))
        #expect(route.member == "a")
        #expect(route.failure == nil)
      }
    }
  }

  @Test(arguments: zip([true, true, false], [true, false, true])) func compactionLeavesOutAHeldMemberWhileItsQuotaResetIsAhead(resetAhead: Bool, otherUsable: Bool) async throws {
    try await withSessionDeps {
      let (harness, owner, source, id) = try await setup()
      var catalog = source
      if !otherUsable {
        catalog.credentials = .bound { provider in
          if provider == "alternate" { throw ChatGPTAuthError.loginRequired(detail: "lapsed other account") }
          return .init(credential: .apiKey("key-" + provider), identityEpoch: provider)
        }
      }
      let reset = resetAhead ? Date().addingTimeInterval(7800) : nil
      #expect(try await recordRouteFailure(InferenceError.rateLimited(retryAt: reset), session: id, store: owner.space.sessions, catalog: catalog)?.retryAt == reset)
      try await owner.space.sessions.deliverMail(id)
      let ready = catalog
      let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "folded", snapshot: .init(), runningWork: [])
      let tokens = head.lines(session: id).estimatedContextTokens(images: .claude)
      let transition = try await compactionPlacement(store: owner.space.sessions, catalog: { _ in ready }, usage: harness.runtime.usage)(id, tokens, nil)
      #expect(transition?.route.member == (resetAhead && otherUsable ? "b" : nil))
    }
  }
}

// `Double.random(in: 0 ... 1)` draws 0 from a constant 1; a constant 0 is rejected forever.
private struct NoJitter: RandomNumberGenerator {
  mutating func next() -> UInt64 { 1 }
}

private func responsesHarness() async throws -> SessionHarness {
  let models = testModelsJSON.replacingOccurrences(of: "\"dialect\": \"anthropic\"", with: "\"dialect\": \"responses\"")
  let harness = try await SessionHarness(assembledModels: models, credentialResolver: .bound { provider in .init(credential: .apiKey("key-" + provider), identityEpoch: provider) })
  try await ModelGroupRouteTests().install(harness)
  return harness
}

private func completedResponse() -> Response {
  let completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n\n"
  return Response(status: .ok, body: .bytes(Data(completed.utf8), contentType: "text/event-stream"))
}
