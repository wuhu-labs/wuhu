import DeterministicDependencies
import Foundation
import ModelProviders
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Testing
import WuhuAI

/// The reply's warming decision, judged once where the reply is built.
@Suite(.deterministicDependencies) struct WarmingScheduleTests {
  private func record(_ kind: SessionKind) -> SessionRecord {
    SessionRecord(
      id: SessionID("s1"), kind: kind, parent: nil, title: "t", tags: [], createdBy: "morgan",
      executor: .kernel(.init(provider: "p", model: "m", effort: "high")),
      createdAt: Date(timeIntervalSinceReferenceDate: 0), lastActivityAt: Date(timeIntervalSinceReferenceDate: 0),
      hold: .normal, work: .noWork, errorMessage: nil, lifecycle: .live, group: .shared,
    )
  }

  private func lines() -> [TranscriptLine] {
    [TranscriptLine(at: Date(timeIntervalSinceReferenceDate: 0), key: "message:m1", message: .user(.init(content: [.text(String(repeating: "a", count: 4000))])))]
  }

  private func policy(floorTokens: Int = 1) -> CacheWarmingPolicy {
    CacheWarmingPolicy(intervalSeconds: 100, lifetimeSeconds: 200, maxPings: 3, floorTokens: floorTokens)
  }

  private let now = Date(timeIntervalSinceReferenceDate: 0)

  @Test func anAgentAtTheFloorWithQuotaLeftKeepsThePolicysSchedule() {
    let schedule = warmingSchedule(record: record(.agent), policy: policy(), lines: lines(), images: .claude, provider: "p", usage: UsageBoard(), at: now)
    #expect(schedule == WarmingSchedule(intervalSeconds: 100, lifetimeSeconds: 200, maxPings: 3))
  }

  @Test func aLowFiveHourWindowLeavesNothingToWarm() {
    let board = UsageBoard()
    board.record("p", plan: nil, windows: [.init(name: "five_hour", usedPercent: 95, resetsAt: nil)], at: now)
    #expect(warmingSchedule(record: record(.agent), policy: policy(), lines: lines(), images: .claude, provider: "p", usage: board, at: now) == nil)
  }

  @Test func aTaskNoPolicyAndAContextUnderTheFloorLeaveNothingToWarm() {
    #expect(warmingSchedule(record: record(.task), policy: policy(), lines: lines(), images: .claude, provider: "p", usage: UsageBoard(), at: now) == nil)
    #expect(warmingSchedule(record: record(.agent), policy: nil, lines: lines(), images: .claude, provider: "p", usage: UsageBoard(), at: now) == nil)
    #expect(warmingSchedule(record: record(.agent), policy: policy(floorTokens: 50000), lines: lines(), images: .claude, provider: "p", usage: UsageBoard(), at: now) == nil)
  }
}
