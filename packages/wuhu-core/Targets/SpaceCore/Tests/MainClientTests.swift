#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import Testing

@Suite struct MainClientTests {
  @Test func everyMessageAndReplyCrossesTheValueBoundary() async throws {
    let sessions = try Space.inMemory().sessions
    let id = try await sessions.createSession(group: .shared, title: "codec", kind: .agent, createdBy: "morgan", model: .test)
    let hydration = try await sessions.hydrate(id)
    guard case let .kernel(transcript) = hydration.transcript else { return }
    try await sessions.requestCommand(id, .compact(instructions: "retain"))
    let claim = try #require(try await sessions.claimCompactRequest(id, generation: hydration.generation))
    let route = SessionModelRoute(group: nil, member: nil, specifier: .test, bindingFingerprint: "binding", epoch: "epoch", reason: .create, placedAt: hydration.record.createdAt, evidence: [])
    let transition = ModelRouteTransition(expectedEpoch: route.epoch, route: route, transcript: transcript)
    let head = GenerationHead(id: UUID(), timestamp: hydration.record.createdAt, summary: "folded", snapshot: .init())
    let events: [SessionEvent] = [
      .modelRouteEstablished(route), .modelRouteFailureUpdated(expectedEpoch: route.epoch, failure: nil),
      .inputEnqueued(.notification(.init(id: UUID(), timestamp: head.timestamp, kind: .timer, subscriptionID: .init("clock"), content: .init(text: "wake")))),
      .pendingCacheWarmingDiscarded, .transcriptAppended(items: transcript.items, transcript: transcript, completing: claim),
      .portableHandoff(expectedGeneration: 0, source: transcript, transcript: transcript, transition: transition),
      .compacted(closing: nil, head: head, kept: 0 ..< 1, completing: claim, transition: transition),
      .interrupted, .resumed, .compactionActivity(.active), .compactionActivity(.inactive), .errored("failed"),
      .archived(grace: Duration(secondsComponent: 3, attosecondsComponent: 17)), .unarchived, .restarted(executor: hydration.record.executor, note: "again", modelRoute: route),
    ]
    let reads: [SessionRead] = [.modelRoute, .record, .hydration, .queueHead, .pendingCommand, .registeredSubscriptions, .scopeContext(.init("call"))]
    let messages = events.map { ToMain.append(id, $0) } + reads.map { ToMain.read(id, $0) } + [.effect(id, .drainQueue), .effect(id, .claimCompactRequest(generation: 0))]
    let replies: [MainReply] = [
      .acknowledged, .modelRoute(route), .modelRoute(nil), .record(hydration.record), .hydration(hydration), .queuePosition(8), .transcript(transcript),
      .scopeContext(nil), .scopeContext(.init(folders: ["/repo": "/repo"], deliveredContext: ["digest": "/repo/AGENTS.md"], text: "instructions")),
      .command(nil), .command(.compact(instructions: "retain")), .subscriptions(.init(ids: [.init("clock")], handlers: [.init("clock")])),
      .queueDrain(.init(items: transcript.items, queueTail: 8)), .compactClaim(claim), .compactClaim(nil),
      .archiveDeadline(head.timestamp), .restart(.init(generation: 1, executor: hydration.record.executor)),
    ]
    for message in messages {
      for reply in replies {
        let main = InProcessMainClient { received in
          let receivedBytes = try Self.encoded(received)
          let sentBytes = try Self.encoded(message)
          #expect(receivedBytes == sentBytes)
          return reply
        }
        #expect(try await Self.encoded(main.send(message)) == Self.encoded(reply))
      }
    }
    #expect(try MainReply.modelRoute(nil).value(SessionModelRoute?.self) == nil)
    #expect(try MainReply.modelRoute(route).value(SessionModelRoute.self) == route)
    #expect(throws: MainContractError.unexpectedReply) { try MainReply.acknowledged.value(Int.self) }
  }

  private static func encoded(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
  }
}
