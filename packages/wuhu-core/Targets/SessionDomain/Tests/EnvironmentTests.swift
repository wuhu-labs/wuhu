import Foundation
@testable import SessionDomain
import Testing

@Suite struct EnvironmentTests {
  private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
  private static let sender = Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!)

  private static func message(_ conversation: String, owesReply: Bool = true, request: String? = nil) -> QueueInput {
    .message(.init(
      id: UUID(), messageID: .init("m-\(conversation)"), conversationID: .init(conversation), sender: sender,
      timestamp: t0, kind: request == nil ? .message : .request, requestID: request.map { RequestID($0) },
      owesReply: owesReply, content: .init(text: "hi"),
    ))
  }

  private static func post(_ conversation: String) -> ToolResultPayload {
    .sendMessage(.init(messageID: .init("p-\(conversation)"), conversationID: .init(conversation), n: 1))
  }

  // Parallel tool calls land as tool results of one log entry in either
  // order; the environment they leave is the same.
  @Test func parallelToolResultsCommute() {
    let results: [ToolResultPayload] = [
      Self.post("a"),
      Self.post("b"),
      .report(.init(messageID: .init("f"), requestID: .init("r1"), conversationID: .init("dm"), kind: .final)),
      .timer(.init(subscriptionID: .init("timer.t"), schedule: .cron("0 * * * *"), message: "tick")),
      .observe(.init(subscriptionID: .init("obs.o"), sql: "SELECT 1")),
      .mount(.init(mount: .init(location: "/notes"), contextVersion: 1, contextEmission: nil)),
      .read(.init(path: "/notes/a.md", revision: .journal(3), content: "x")),
      .exec(.init(output: "", exitCode: 0)),
    ]
    var before = SessionEnvironment()
    for input in [Self.message("a"), Self.message("b"), Self.message("dm", request: "r1")] {
      before.apply(.delivered(input, at: Self.t0))
    }
    var forward = before
    var backward = before
    for result in results { forward.apply(.toolResult(result, at: Self.t0)) }
    for result in results.reversed() { backward.apply(.toolResult(result, at: Self.t0)) }
    #expect(forward == backward)
    #expect(forward.settle.owedConversations.isEmpty, "the final report went into the request's conversation")
    #expect(forward.settle.openRequests.isEmpty)
    #expect(forward.tools.fileAccessLog == ["/notes/a.md": .journal(3)])
  }

  @Test func anAgentIsNaggedOncePerUnansweredDelivery() {
    var environment = SessionEnvironment()
    environment.apply(.delivered(Self.message("box"), at: Self.t0))
    let nag = Nag.owedReply(conversations: [.init("box")])
    #expect(environment.nag(task: false, now: Self.t0) == nag)
    environment.apply(.nagged(nag, at: Self.t0))
    #expect(environment.nag(task: false, now: Self.t0) == nil)
    environment.apply(.delivered(Self.message("box"), at: Self.t0))
    #expect(environment.nag(task: false, now: Self.t0) == nag, "a new delivery owes again")
    environment.apply(.toolResult(Self.post("box"), at: Self.t0))
    #expect(environment.nag(task: false, now: Self.t0) == nil)
    #expect(environment.nextTimer(now: Self.t0) == nil)
  }

  @Test func anAgentWithAnOpenRequestIsRemindedAfterItsOwedReplies() {
    var environment = SessionEnvironment()
    environment.apply(.delivered(Self.message("dm", owesReply: false, request: "r1"), at: Self.t0))
    environment.apply(.delivered(Self.message("box"), at: Self.t0))
    let owed = Nag.owedReply(conversations: [.init("box")])
    #expect(environment.nag(task: false, now: Self.t0) == owed, "the reply is owed first")
    environment.apply(.nagged(owed, at: Self.t0))
    let park = Nag.park(request: .init("r1"))
    #expect(environment.nag(task: false, now: Self.t0) == park)
    environment.apply(.nagged(park, at: Self.t0))
    #expect(environment.nextTimer(now: Self.t0) == Self.t0.addingTimeInterval(60))
    environment.apply(.toolResult(.report(.init(messageID: .init("f"), requestID: .init("r1"), conversationID: .init("dm"), kind: .final)), at: Self.t0))
    #expect(environment.nag(task: false, now: Self.t0.addingTimeInterval(60)) == nil)
    #expect(environment.nextTimer(now: Self.t0) == nil)
  }

  @Test func aParkedTaskIsRemindedOnTheBackoffUnlessATimerIsArmed() {
    var environment = SessionEnvironment()
    environment.apply(.delivered(Self.message("dm", owesReply: false, request: "r1"), at: Self.t0))
    let nag = Nag.park(request: .init("r1"))
    #expect(environment.nag(task: true, now: Self.t0) == nag, "the first reminder is due at once")
    environment.apply(.nagged(nag, at: Self.t0))
    #expect(environment.nag(task: true, now: Self.t0) == nil)
    #expect(environment.nextTimer(now: Self.t0) == Self.t0.addingTimeInterval(60))
    #expect(environment.nag(task: true, now: Self.t0.addingTimeInterval(60)) == nag)

    var timed = environment
    timed.apply(.toolResult(.timer(.init(subscriptionID: .init("timer.t"), schedule: .oneShot(Self.t0), message: "m")), at: Self.t0))
    #expect(timed.nag(task: true, now: Self.t0.addingTimeInterval(60)) == nil, "a timer is certain to wake it")
    #expect(timed.nextTimer(now: Self.t0) == nil)

    environment.apply(.toolResult(.report(.init(messageID: .init("f"), requestID: .init("r1"), conversationID: .init("dm"), kind: .final)), at: Self.t0))
    #expect(environment.nextTimer(now: Self.t0) == nil)
  }

  @Test func aNagRendersWithTheKernelsHeaderTags() {
    let at = Date(timeIntervalSince1970: 1_790_140_000)
    #expect(Nag.park(request: .init("r1")).rendered(at: at) == """
    <sender>system</sender>
    <timestamp>2026-09-23T05:06:40Z</timestamp>
    <source>park.r1</source>
    <type>park reminder</type>

    \(SessionPrompt.parkReminder(request: "r1"))
    """)
  }
}
