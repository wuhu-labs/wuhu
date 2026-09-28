import Foundation
import SessionDomain
import Testing
import WuhuAI

@Suite struct EstimatorTests {
  private func estimated(_ text: String) -> Int {
    Int((Double(text.utf8.count) / 4.0).rounded(.up))
  }

  private func bodyEstimate(of item: TranscriptItem) -> Int {
    guard case let .direct(message) = item else {
      Issue.record("fixture shape")
      return 0
    }
    return estimated(message.header.render() + "\n\n" + message.content.text)
  }

  @Test func `carried usage below keptCount is not trusted`() {
    let tail = Fix.direct(text: "hello world")
    let transcript = Transcript(items: [Fix.assistant(totalTokens: 1_000_000), tail], keptCount: 1)
    #expect(transcript.estimatedContextTokens(images: .claude) == bodyEstimate(of: tail))
  }

  @Test func `fresh usage is trusted and the tail after it is estimated`() {
    let tail = Fix.direct(text: "follow-up question")
    let transcript = Transcript(items: [
      Fix.direct(text: "carried input"),
      Fix.assistant(totalTokens: 12345),
      tail,
    ], keptCount: 1)
    #expect(transcript.estimatedContextTokens(images: .claude) == 12345 + bodyEstimate(of: tail))
  }

  @Test func `the last fresh usage wins`() {
    let transcript = Transcript(items: [
      Fix.assistant(totalTokens: 100),
      Fix.direct(text: "x"),
      Fix.assistant(totalTokens: 250),
    ])
    #expect(transcript.estimatedContextTokens(images: .claude) == 250)
  }

  @Test func `no fresh usage means everything is estimated`() {
    let a = Fix.direct(text: "one")
    let b = Fix.direct(text: "two")
    let transcript = Transcript(items: [a, b])
    #expect(transcript.estimatedContextTokens(images: .claude) == bodyEstimate(of: a) + bodyEstimate(of: b))
  }

  @Test func `usable context reserves maxOutput unless overridden`() {
    #expect(ContextBudget(maxInput: 1000, maxOutput: 200).usableTokens == 800)
    #expect(ContextBudget(maxInput: 1000, maxOutput: 200, headroomOverride: 100).usableTokens == 900)
  }

  @Test func `fullness is the estimate over usable context`() {
    let transcript = Transcript(items: [Fix.assistant(totalTokens: 400)])
    let fullness = transcript.contextFullness(budget: .init(maxInput: 1000, maxOutput: 200))
    #expect(fullness == 0.5)
  }
}
