import Foundation
import SessionDomain
import Testing

// The kernel's side of the session environment: the fold read straight off a
// transcript, in transcript order.
@Suite struct TranscriptEnvironmentTests {
  private static let later = Fix.instant.addingTimeInterval(60)

  private static func environment(_ items: [TranscriptItem], keptCount: Int = 0) -> SessionEnvironment {
    Transcript(items: items, keptCount: keptCount).environment
  }

  private static func nag(_ nag: Nag, at: Date = Fix.instant) -> TranscriptItem {
    .notification(nag.notification(id: UUID(), at: at))
  }

  private static let request = Fix.message(id: "r1", conversation: "dm", kind: .request, request: "r1", owesReply: false)
  private static let park = Nag.park(request: RequestID("r1"))

  private static func requested(_ task: String, deadline: Date?) -> TranscriptItem {
    Fix.result(.request(.init(requestID: .init("c1"), task: .init(task), conversationID: .init("dm-\(task)"), deadline: deadline)))
  }

  @Test func `an agent owes in transcript order and is reminded once per delivery`() {
    let owed = Nag.owedReply(conversations: [.init("box")])
    var items = [Fix.message(conversation: "box")]
    #expect(Self.environment(items).nag(task: false, now: Fix.instant) == owed)
    items.append(Self.nag(owed))
    #expect(Self.environment(items).nag(task: false, now: Fix.instant) == nil, "the nag in the transcript is the record that it was shown")
    items.append(Fix.message(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, now: Fix.instant) == owed, "a new delivery owes again")
    items.append(Fix.post(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, now: Fix.instant) == nil)
    items.append(Fix.message(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, now: Fix.instant) == owed, "a delivery after the post owes, whatever its timestamp")
    #expect(Self.environment([Fix.message(conversation: "grp", owesReply: false)]).nag(task: false, now: Fix.instant) == nil)
  }

  @Test func `a task's park reminders back off from the ones its transcript shows`() {
    let items = [Self.request, Self.nag(Self.park)]
    let environment = Self.environment(items)
    #expect(environment.nag(task: true, now: Fix.instant) == nil)
    #expect(environment.nextTimer(now: Fix.instant) == Self.later)
    let second = Self.environment(items + [Self.nag(Self.park, at: Self.later)])
    #expect(second.nextTimer(now: Self.later) == Self.later.addingTimeInterval(300))
    let reported = Self.environment(items + [Fix.result(.report(.init(messageID: .init("f"), requestID: .init("r1"), conversationID: .init("dm"), kind: .final)))])
    #expect(reported.nextTimer(now: Fix.instant) == nil)
  }

  @Test func `an armed timer keeps a task from being nagged`() {
    let timer = Fix.result(.timer(.init(subscriptionID: .init("timer.t"), schedule: .oneShot(Self.later), message: "m")))
    #expect(Self.environment([Self.request]).nag(task: true, now: Fix.instant) == Self.park)
    #expect(Self.environment([Self.request, timer]).nag(task: true, now: Fix.instant) == nil)
    #expect(Self.environment([Self.request, timer]).nextTimer(now: Fix.instant) == nil)
    let fired = Fix.notification(kind: .timer, subscription: "timer.t", endsSubscription: true)
    #expect(Self.environment([Self.request, timer, fired]).nag(task: true, now: Fix.instant) == Self.park, "a fired one-shot wakes nothing more")
  }

  @Test func `a deadline on a request to a child keeps a task from being nagged until the child's final`() {
    let bounded = Self.requested("child", deadline: Self.later)
    #expect(Self.environment([Self.request, bounded]).nag(task: true, now: Fix.instant) == nil)
    #expect(Self.environment([Self.request, Self.requested("child", deadline: nil)]).nag(task: true, now: Fix.instant) == Self.park)

    let final = Fix.message(id: "f", conversation: "dm-child", kind: .final, request: "c1", owesReply: false)
    #expect(Self.environment([Self.request, bounded, final]).nag(task: true, now: Fix.instant) == Self.park)
    let expired = Fix.notification(kind: .requestDeadline, subscription: "deadline.c1", endsSubscription: true)
    #expect(Self.environment([Self.request, bounded, expired]).nag(task: true, now: Fix.instant) == Self.park)
  }

  @Test func `an observation does not keep a task from being nagged`() {
    let observing = Fix.result(.observe(.init(subscriptionID: .init("obs.o"), sql: "SELECT 1")))
    #expect(Self.environment([Self.request, observing]).nag(task: true, now: Fix.instant) == Self.park)
  }

  @Test func `a compaction head carries the settle state and its carried tail is not counted twice`() {
    let items = [Self.request, Self.nag(Self.park), Self.nag(Self.park, at: Self.later)]
    let closed = Transcript(items: items)
    let head = GenerationHead(
      id: UUID(), timestamp: Self.later, summary: "s", snapshot: .init(), settle: closed.environment.settle,
    )
    let carried = closed.compacted(head: head, kept: 2 ..< 3)
    #expect(carried.environment == closed.environment)
    #expect(carried.environment.settle.openRequests[RequestID("r1")]?.parkReminderCount == 2)
  }
}
