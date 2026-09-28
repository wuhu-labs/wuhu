import Foundation
import SessionDomain
import Testing

@Suite struct CutPointTests {
  private func estimated(_ text: String) -> Int {
    Int((Double(text.utf8.count) / 4.0).rounded(.up))
  }

  private func estimate(of item: TranscriptItem) -> Int {
    switch item {
    case let .direct(message):
      return estimated(message.header.render() + "\n\n" + message.content.text)
    case let .toolResult(result):
      guard case let .grep(grep) = result.payload else {
        Issue.record("fixture shape")
        return 0
      }
      return estimated(grep.output)
    default:
      Issue.record("fixture shape")
      return 0
    }
  }

  @Test func `a fitting non-tool-result entry becomes the cut`() {
    let a = Fix.direct(text: String(repeating: "a", count: 400))
    let b = Fix.direct(text: "short tail")
    let transcript = Transcript(items: [a, b])
    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: b), images: .claude) == 1)
    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: a) + estimate(of: b), images: .claude) == 0)
  }

  @Test func `nothing fits means summarize everything`() {
    let transcript = Transcript(items: [Fix.direct(text: String(repeating: "a", count: 400))])
    #expect(transcript.compactionCutIndex(keptTokens: 1, images: .claude) == nil)
  }

  @Test func `the cut never lands on a tool result`() {
    let a = Fix.direct(text: String(repeating: "a", count: 400))
    let r = Fix.result(.grep(.init(output: String(repeating: "m", count: 100))))
    let b = Fix.direct(text: "short tail")
    let transcript = Transcript(items: [a, r, b])

    // Budget covers r + b, but r cannot be the cut: its call would be
    // summarized away. The cut stays at b until a also fits.
    let budget = estimate(of: r) + estimate(of: b)
    #expect(transcript.compactionCutIndex(keptTokens: budget, images: .claude) == 2)
    let everything = estimate(of: a) + estimate(of: r) + estimate(of: b)
    #expect(transcript.compactionCutIndex(keptTokens: everything, images: .claude) == 0)
  }

  @Test func `a trailing tool result is never orphaned`() {
    let a = Fix.direct(text: String(repeating: "a", count: 400))
    let r = Fix.result(.grep(.init(output: String(repeating: "m", count: 100))))
    let transcript = Transcript(items: [a, r])

    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: r), images: .claude) == nil)
    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: a) + estimate(of: r), images: .claude) == 0)
  }
}
