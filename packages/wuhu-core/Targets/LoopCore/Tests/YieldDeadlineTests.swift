import ControlledTime
import Foundation
@testable import LoopCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct YieldDeadlineTests {
  let clock = VirtualClock()
  let start = Date(timeIntervalSince1970: 1_700_000_000)

  func waiting(_ deadline: YieldDeadline) -> Task<Bool, Never> {
    let (clock, start) = (clock, start)
    return Task {
      await deadline.passed(now: { start.addingTimeInterval(Double(clock.now.offset.components.seconds)) }, sleep: { duration in { try await clock.sleep(for: duration) } })
    }
  }

  @Test func `an earlier deadline cuts the wait short`() async throws {
    let deadline = YieldDeadline(start.addingTimeInterval(90))
    let waiting = waiting(deadline)
    try await clock.sleeping { $0 == .seconds(90) }
    deadline.offer(start.addingTimeInterval(60))
    deadline.offer(start.addingTimeInterval(80))
    try await clock.sleeping { $0 == .seconds(60) }
    await clock.advance(by: .seconds(60))
    #expect(await waiting.value)
    #expect(deadline.by == start.addingTimeInterval(60))
  }

  @Test func `no deadline waits until one comes`() async throws {
    let deadline = YieldDeadline(nil)
    let waiting = waiting(deadline)
    await clock.advance(by: .seconds(600))
    deadline.offer(start.addingTimeInterval(610))
    try await clock.sleeping { $0 == .seconds(10) }
    await clock.advance(by: .seconds(10))
    #expect(await waiting.value)
  }
}
