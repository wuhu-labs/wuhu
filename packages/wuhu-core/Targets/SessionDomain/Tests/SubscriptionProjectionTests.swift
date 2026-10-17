import Foundation
import SessionDomain
import Testing

@Suite struct SubscriptionProjectionTests {
  @Test func projectionReconcilesOnlyPublicSubscriptionsAfterTheWholeFold() throws {
    let timer = SubscriptionID("timer")
    let observer = SubscriptionID("observer")
    let deadline = SubscriptionID.deadline(.init("r"))
    var transcript = Transcript(items: [
      Fix.result(.timer(.init(subscriptionID: timer, schedule: .oneShot(Fix.instant), message: "tick"))),
      Fix.result(.observe(.init(subscriptionID: observer, sql: "SELECT 1"))),
      Fix.result(.read(.init(path: "/file.md", revision: .journal(7), content: "body"))),
    ])
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "snapshot", snapshot: .init(subscriptions: [deadline: .requestDeadline(Fix.instant)]))
    transcript.items.insert(.generationHead(head), at: 0)
    #expect(transcript.environment.tools.subscriptions.count == 3, "unprojected pure transcript folding stays compatible")
    transcript.registeredSubscriptions = [observer]
    transcript.handlerSubscriptions = [observer]
    #expect(transcript.environment.tools.subscriptions == [observer: .observe(sql: "SELECT 1"), deadline: .requestDeadline(Fix.instant)])
    #expect(transcript.environment.tools.fileAccessLog["/file.md"] == .journal(7))
    let stale = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "compact", snapshot: .init(subscriptions: [timer: .timer(.oneShot(Fix.instant)), observer: .observe(sql: "SELECT 1")]))
    let compacted = transcript.compacted(head: stale, kept: 1 ..< transcript.items.count)
    #expect(compacted.registeredSubscriptions == [observer])
    #expect(compacted.handlerSubscriptions == [observer])
    #expect(compacted.environment.tools.handlerSubscriptions == [observer])
    #expect(compacted.environment.tools.subscriptions == [observer: .observe(sql: "SELECT 1")])
    guard case let .generationHead(savedHead) = compacted.items[0] else { Issue.record("missing head"); return }
    #expect(savedHead.snapshot.subscriptions == [observer: .observe(sql: "SELECT 1")])
  }

  @Test func projectionIsTransientAndLegacyCodableBytesStayIdentical() throws {
    let original = Transcript(items: [Fix.result(.timer(.init(subscriptionID: .init("timer"), schedule: .oneShot(Fix.instant), message: "tick")))])
    var projected = original
    projected.registeredSubscriptions = []
    projected.handlerSubscriptions = [.init("timer")]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(projected) == encoder.encode(original))
    let decoded = try JSONDecoder().decode(Transcript.self, from: encoder.encode(projected))
    #expect(decoded.registeredSubscriptions == nil)
    #expect(decoded.handlerSubscriptions.isEmpty)
    #expect(decoded == original)
    #expect(projected.environment.tools.subscriptions.isEmpty)
    #expect(decoded.environment.tools.subscriptions.count == 1, "the receiving store/runtime must supply its fresh registration snapshot")
  }

  @Test func renderProjectsRetiredHeadSubscriptionsWithoutChangingHistory() async throws {
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "summary", snapshot: .init(subscriptions: [.init("timer.old"): .timer(.oneShot(Fix.instant))], preReads: ["/keep.md"]))
    let transcript = Transcript(items: [.generationHead(head)], registeredSubscriptions: [])
    let request = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    guard case let .text(text)? = request.messages.first?.user?.content.first else { Issue.record("missing snapshot"); return }
    #expect(text.text.contains("active subscriptions: none"))
    #expect(text.text.contains("/keep.md"))
    #expect(transcript.items == [.generationHead(head)])
    #expect(head.snapshot.subscriptions.count == 1)
    #expect(request.messages.count == 3)
  }

  @Test func theHeadListsTheRunningWorkTheTranscriptCarries() async throws {
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "summary", snapshot: .init(preReads: ["/a.md"]))
    func snapshotText(_ transcript: Transcript) async -> String? {
      let request = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
      guard case let .text(text)? = request.messages.first?.user?.content.first else { return nil }
      return text.text
    }
    let busy = Transcript(items: [.generationHead(head)], runningWork: ["script.ffff0000", "exec.ex_0a1b2c3d"])
    #expect(await snapshotText(busy)?.contains("running: exec.ex_0a1b2c3d, script.ffff0000\n") == true)
    #expect(await snapshotText(Transcript(items: [.generationHead(head)]))?.contains("running: none\n") == true)
  }

  @Test func toolHandlerMetadataDoesNotChangeLegacyCodableBytes() throws {
    let original = ToolExecutionState(subscriptions: [.init("timer"): .timer(.oneShot(Fix.instant))])
    var metadata = original
    metadata.handlerSubscriptions = [.init("timer")]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(metadata) == encoder.encode(original))
    let decoded = try JSONDecoder().decode(ToolExecutionState.self, from: encoder.encode(metadata))
    #expect(decoded == original)
    #expect(decoded.handlerSubscriptions.isEmpty)
  }

  @Test(arguments: [false, true])
  func handlerTimerDoesNotSuppressRequestParkBackstop(cron: Bool) {
    let request = RequestID("r1")
    let subscription = SubscriptionID("timer.handler")
    let schedule: TimerSchedule = cron ? .cron("* * * * *") : .oneShot(Fix.instant.addingTimeInterval(60))
    var transcript = Transcript(items: [
      Fix.message(id: "r1", conversation: "dm", kind: .request, request: "r1", owesReply: false),
      Fix.result(.timer(.init(subscriptionID: subscription, schedule: schedule, message: "tick"))),
    ])
    #expect(transcript.environment.nag(task: true, now: Fix.instant) == nil, "plain timers remain guaranteed model wakes")
    transcript.handlerSubscriptions = [subscription]
    let park = Nag.park(request: request)
    #expect(transcript.environment.nag(task: true, now: Fix.instant) == park)
    transcript.append(.notification(park.notification(id: UUID(), at: Fix.instant)))
    #expect(transcript.environment.nextTimer(now: Fix.instant) == Fix.instant.addingTimeInterval(60))
    let head = GenerationHead(
      id: UUID(), timestamp: Fix.instant, summary: "compact",
      snapshot: .init(carrying: transcript.environment.tools, preReads: []), settle: transcript.environment.settle,
    )
    let compacted = transcript.compacted(head: head, kept: nil)
    #expect(compacted.handlerSubscriptions == [subscription])
    #expect(compacted.environment.nextTimer(now: Fix.instant) == Fix.instant.addingTimeInterval(60))
    transcript.append(Fix.result(.request(.init(requestID: .init("child"), task: .init("task"), conversationID: .init("child-dm"), deadline: Fix.instant.addingTimeInterval(60)))))
    #expect(transcript.environment.nextTimer(now: Fix.instant) == nil, "outgoing request deadlines remain guaranteed wakes")
  }
}
