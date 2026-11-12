#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing
import WuhuAI

@Suite struct RecentTailTests {
  private let small = 200
  private let everything = 1_000_000
  private let big = String(repeating: "a", count: 4000)

  private func estimate(of item: TranscriptItem) -> Int {
    item.lines(session: Fix.session).estimatedContextTokens(images: .claude)
  }

  private func turn(_ ids: String...) -> TranscriptItem {
    Fix.assistant(text: big, totalTokens: 1, toolCalls: ids.map { ToolCall(id: $0, name: "grep", arguments: .object([:])) })
  }

  private func result(_ id: String) -> TranscriptItem {
    Fix.result(.grep(.init(output: "match")), provenance: .toolCall(.init(id)))
  }

  @Test func `a fitting non-tool-result entry becomes the cut`() {
    let a = Fix.message(text: big)
    let b = Fix.message(text: "short tail")
    let items: [TranscriptItem] = [a, b]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: estimate(of: b), images: .claude) == 1)
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: estimate(of: a) + estimate(of: b), images: .claude) == 0)
  }

  @Test func `nothing fits means no carried tail`() {
    let items: [TranscriptItem] = [Fix.message(text: big)]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: 1, images: .claude) == nil)
  }

  @Test func `the cut never lands on a tool result`() {
    let items: [TranscriptItem] = [Fix.message(), turn("k-1"), result("k-1"), Fix.message(text: "short tail")]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: small, images: .claude) == 3)
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: everything, images: .claude) == 0)
  }

  @Test func `a trailing tool result is never orphaned`() {
    let items: [TranscriptItem] = [Fix.message(), turn("k-1"), result("k-1")]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: small, images: .claude) == nil)
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: everything, images: .claude) == 0)
  }

  @Test func `a notice between parallel results is never the cut`() {
    let items: [TranscriptItem] = [
      Fix.message(), turn("k-1", "k-2"), result("k-1"),
      Fix.notification(kind: .context, subscription: "machine-notes", text: "notes"),
      result("k-2"), Fix.message(text: "short tail"),
    ]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: small, images: .claude) == 5)
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: everything, images: .claude) == 0)
  }

  @Test func `a bookmark answers its call like a result`() {
    let bookmark = TranscriptItem.bookmark(.init(id: UUID(), timestamp: Fix.instant, name: "here", toolCallID: .init("k-2")))
    let items: [TranscriptItem] = [Fix.message(), turn("k-1", "k-2"), result("k-1"), bookmark]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: small, images: .claude) == nil)
  }

  @Test func `a result whose call is gone is never kept`() {
    let tail = Fix.message(text: "short tail")
    let items = [Fix.message(), result("lost"), tail]
    #expect(items.flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: everything, images: .claude) == 2)
    #expect([Fix.message(), result("lost")].flatMap { $0.lines(session: Fix.session) }.recentTail(tokens: everything, images: .claude) == nil)
  }
}
