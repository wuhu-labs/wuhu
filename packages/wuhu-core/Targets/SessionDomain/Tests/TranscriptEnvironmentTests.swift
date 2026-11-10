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
  private static let open = [OpenRequest(id: RequestID("r1"))]

  @Test func `an agent owes in transcript order and is reminded once per delivery`() {
    let owed = Nag.owedReply(conversations: [.init("box")])
    var items = [Fix.message(conversation: "box")]
    #expect(Self.environment(items).nag(task: false, openRequests: [], now: Fix.instant) == owed)
    items.append(Self.nag(owed))
    #expect(Self.environment(items).nag(task: false, openRequests: [], now: Fix.instant) == nil, "the nag in the transcript is the record that it was shown")
    items.append(Fix.message(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, openRequests: [], now: Fix.instant) == owed, "a new delivery owes again")
    items.append(Fix.post(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, openRequests: [], now: Fix.instant) == nil)
    items.append(Fix.message(conversation: "box"))
    #expect(Self.environment(items).nag(task: false, openRequests: [], now: Fix.instant) == owed, "a delivery after the post owes, whatever its timestamp")
    #expect(Self.environment([Fix.message(conversation: "grp", owesReply: false)]).nag(task: false, openRequests: [], now: Fix.instant) == nil)
  }

  @Test func `a task's park reminders back off from the ones its transcript shows`() {
    let items = [Self.request, Self.nag(Self.park)]
    let environment = Self.environment(items)
    #expect(environment.nag(task: true, openRequests: Self.open, now: Fix.instant) == nil)
    #expect(environment.nextTimer(openRequests: Self.open, now: Fix.instant) == Self.later)
    let second = Self.environment(items + [Self.nag(Self.park, at: Self.later)])
    #expect(second.nextTimer(openRequests: Self.open, now: Self.later) == Self.later.addingTimeInterval(300))
    #expect(environment.nextTimer(openRequests: [], now: Fix.instant) == nil, "a closed request is owed nothing")
  }

  @Test func `an armed timer keeps a task from being nagged`() {
    let timer = Fix.result(.timer(.init(subscriptionID: .init("timer.t"), schedule: .oneShot(Self.later), message: "m")))
    #expect(Self.environment([Self.request]).nag(task: true, openRequests: Self.open, now: Fix.instant) == Self.park)
    #expect(Self.environment([Self.request, timer]).nag(task: true, openRequests: Self.open, now: Fix.instant) == nil)
    #expect(Self.environment([Self.request, timer]).nextTimer(openRequests: Self.open, now: Fix.instant) == nil)
    let fired = Fix.notification(kind: .timer, subscription: "timer.t", endsSubscription: true)
    #expect(Self.environment([Self.request, timer, fired]).nag(task: true, openRequests: Self.open, now: Fix.instant) == Self.park, "a fired one-shot wakes nothing more")
  }

  @Test func `an observation does not keep a task from being nagged`() {
    let observing = Fix.result(.observe(.init(subscriptionID: .init("obs.o"), source: .query("SELECT 1"))))
    #expect(Self.environment([Self.request, observing]).nag(task: true, openRequests: Self.open, now: Fix.instant) == Self.park)
  }

  @Test func `a compaction head carries the settle state and the backoff restarts from the carried tail`() {
    let items = [Self.request, Self.nag(Self.park), Self.nag(Self.park, at: Self.later)]
    let closed = Transcript(items: items)
    let head = GenerationHead(
      id: UUID(), timestamp: Self.later, summary: "s", snapshot: .init(), settle: closed.environment.settle,
      runningWork: [],
    )
    let carried = closed.compacted(head: head, kept: 2 ..< 3)
    #expect(carried.environment.settle == closed.environment.settle)
    #expect(closed.environment.nextTimer(openRequests: Self.open, now: Self.later) == Self.later.addingTimeInterval(300))
    #expect(carried.environment.nextTimer(openRequests: Self.open, now: Self.later) == Self.later.addingTimeInterval(60))
  }

  @Test func `park reminders back off 1, 5, 15 minutes, then flat`() {
    var items = [Self.request]
    #expect(Self.environment(items).nextTimer(openRequests: Self.open, now: Fix.instant) == Fix.instant)
    for delay in [60.0, 300, 900, 900] {
      items.append(Self.nag(Self.park))
      #expect(Self.environment(items).nextTimer(openRequests: Self.open, now: Fix.instant) == Fix.instant.addingTimeInterval(delay))
    }
  }
}
