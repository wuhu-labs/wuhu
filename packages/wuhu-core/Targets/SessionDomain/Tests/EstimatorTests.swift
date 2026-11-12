#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing
import WuhuAI

@Suite struct EstimatorTests {
  private func user(_ text: String) -> TranscriptLine {
    .init(at: Fix.instant, key: "message:test", message: .user(.init(content: [.text(text)])))
  }

  @Test func carriedUsageIsRemovedAndAllCarriedContentIsEstimated() throws {
    let original = try #require(Fix.assistant(text: "old reply", totalTokens: 1_000_000).lines(session: Fix.session).first)
    let carried = try #require(original.carried(portable: false))
    let lines = [carried, user("hello world")]
    #expect(carried.meta == nil)
    #expect(lines.estimatedContextTokens(images: .claude) == estimateTokens("old reply") + estimateTokens("hello world"))
  }

  @Test func freshUsageIsTrustedAndOnlyTheTailIsEstimated() {
    let reply = Fix.assistant(totalTokens: 12345).lines(session: Fix.session)
    let lines = [user("carried input")] + reply + [user("follow-up question")]
    #expect(lines.estimatedContextTokens(images: .claude) == 12345 + estimateTokens("follow-up question"))
  }

  @Test func lastFreshUsageWins() {
    let lines = Fix.assistant(totalTokens: 100).lines(session: Fix.session) + [user("x")] + Fix.assistant(totalTokens: 250).lines(session: Fix.session)
    #expect(lines.estimatedContextTokens(images: .claude) == 250)
  }

  @Test func noFreshUsageMeansEverythingIsEstimated() {
    #expect([user("one"), user("two")].estimatedContextTokens(images: .claude) == 2)
    #expect([TranscriptLine]().estimatedContextTokens(images: .claude) == 0)
    #expect(estimateTokens("ééé") == 2)
  }

  @Test func usableContextReservesOutputUnlessOverridden() {
    #expect(ContextBudget(maxInput: 1000, maxOutput: 200).usableTokens == 800)
    #expect(ContextBudget(maxInput: 1000, maxOutput: 200, headroomOverride: 100).usableTokens == 900)
    #expect(Fix.assistant(totalTokens: 400).lines(session: Fix.session).contextFullness(budget: .init(maxInput: 1000, maxOutput: 200)) == 0.5)
  }
}
