import Foundation
import SessionDomain
import Testing
import WuhuAI

@Suite struct CutPointTests {
  // `small` covers any few short fixture items and never one `big` item.
  private let small = 200
  private let everything = 1_000_000
  private let big = String(repeating: "a", count: 4000)

  private func estimate(of item: TranscriptItem) -> Int {
    guard case let .direct(message) = item else {
      Issue.record("fixture shape")
      return 0
    }
    return Int((Double((message.header.render() + "\n\n" + message.content.text).utf8.count) / 4.0).rounded(.up))
  }

  private func turn(_ ids: String...) -> TranscriptItem {
    Fix.assistant(text: big, totalTokens: 1, toolCalls: ids.map { ToolCall(id: $0, name: "grep", arguments: .object([:])) })
  }

  private func result(_ id: String) -> TranscriptItem {
    Fix.result(.grep(.init(output: "match")), provenance: .toolCall(.init(id)))
  }

  @Test func `a fitting non-tool-result entry becomes the cut`() {
    let a = Fix.direct(text: big)
    let b = Fix.direct(text: "short tail")
    let transcript = Transcript(items: [a, b])
    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: b), images: .claude) == 1)
    #expect(transcript.compactionCutIndex(keptTokens: estimate(of: a) + estimate(of: b), images: .claude) == 0)
  }

  @Test func `nothing fits means summarize everything`() {
    let transcript = Transcript(items: [Fix.direct(text: big)])
    #expect(transcript.compactionCutIndex(keptTokens: 1, images: .claude) == nil)
  }

  @Test func `the cut never lands on a tool result`() {
    let transcript = Transcript(items: [Fix.direct(), turn("k-1"), result("k-1"), Fix.direct(text: "short tail")])
    #expect(transcript.compactionCutIndex(keptTokens: small, images: .claude) == 3)
    #expect(transcript.compactionCutIndex(keptTokens: everything, images: .claude) == 0)
  }

  @Test func `a trailing tool result is never orphaned`() {
    let transcript = Transcript(items: [Fix.direct(), turn("k-1"), result("k-1")])
    #expect(transcript.compactionCutIndex(keptTokens: small, images: .claude) == nil)
    #expect(transcript.compactionCutIndex(keptTokens: everything, images: .claude) == 0)
  }

  @Test func `a notice between parallel results is never the cut`() {
    let transcript = Transcript(items: [
      Fix.direct(), turn("k-1", "k-2"), result("k-1"),
      Fix.notification(kind: .context, subscription: "machine-notes", text: "notes"),
      result("k-2"), Fix.direct(text: "short tail"),
    ])
    #expect(transcript.compactionCutIndex(keptTokens: small, images: .claude) == 5)
    #expect(transcript.compactionCutIndex(keptTokens: everything, images: .claude) == 0)
  }

  @Test func `a bookmark answers its call like a result`() {
    let bookmark = TranscriptItem.bookmark(.init(id: UUID(), timestamp: Fix.instant, name: "here", toolCallID: .init("k-2")))
    let transcript = Transcript(items: [Fix.direct(), turn("k-1", "k-2"), result("k-1"), bookmark])
    #expect(transcript.compactionCutIndex(keptTokens: small, images: .claude) == nil)
  }

  @Test func `a result whose call is gone is folded, never kept`() {
    let tail = Fix.direct(text: "short tail")
    #expect(Transcript(items: [Fix.direct(), result("lost"), tail]).compactionCutIndex(keptTokens: everything, images: .claude) == 2)
    #expect(Transcript(items: [Fix.direct(), result("lost")]).compactionCutIndex(keptTokens: everything, images: .claude) == nil)
  }
}
