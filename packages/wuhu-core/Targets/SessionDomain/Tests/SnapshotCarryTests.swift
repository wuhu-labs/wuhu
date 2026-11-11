import Foundation
import SessionDomain
import Testing
import WuhuAI

@Suite struct SnapshotCarryTests {
  private var workedTranscript: Transcript {
    Transcript(items: [
      Fix.message(sender: "alice"),
      Fix.result(.read(.init(path: "space://a.md", revision: .journal(7), content: "body"))),
      Fix.result(.exec(.init(output: "", exitCode: 0))),
      Fix.context(["machines://m1/repo": "machines://m1/repo"], text: "ctx"),
      Fix.result(.timer(.init(subscriptionID: .init("tim-1"), schedule: .cron("0 * * * *"), message: "wake"))),
    ])
  }

  @Test func `compacted transcript starts at its head and marks everything carried`() {
    let transcript = workedTranscript
    let head = GenerationHead(
      id: UUID(),
      timestamp: Fix.instant,
      summary: "did things",
      snapshot: StateSnapshot(),
      runningWork: [],
    )
    let next = transcript.compacted(head: head, kept: nil)
    #expect(next.items == [.generationHead(head)])
    #expect(next.keptCount == 1)

    let cut = transcript.compacted(head: head, kept: 4 ..< 5)
    #expect(cut.items.count == 2)
    #expect(cut.keptCount == 2)
    #expect(cut.items.first == .generationHead(head))
    #expect(cut.items.last == transcript.items[4])
  }
}
