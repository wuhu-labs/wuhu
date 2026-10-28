import Foundation
import SessionDomain
import Testing
import WuhuAI

@Suite struct FoldTests {
  private func state(_ items: [TranscriptItem]) -> ToolExecutionState {
    Transcript(items: items).environment.tools
  }

  @Test func `delivered context hashes replay with first-source attribution and reset across a retained tail`() throws {
    let first = ScopeContext(folders: ["machines://m1/repo": "machines://m1/repo"], deliveredContext: ["hash": "first/AGENTS.md"], text: "manual")
    let duplicate = ScopeContext(folders: ["machines://m2/repo": "machines://m2/repo"], deliveredContext: ["hash": "second/AGENTS.md"], text: "identical")
    let original = Transcript(items: [
      .notification(first.notice(id: UUID(), at: Fix.instant)),
      .notification(duplicate.notice(id: UUID(), at: Fix.instant)),
    ])
    let replayed = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(original))
    #expect(replayed.environment.tools.deliveredContext == ["hash": "first/AGENTS.md"])
    let compacted = replayed.compacted(head: .init(id: UUID(), timestamp: Fix.instant, summary: "summary", snapshot: .init(), runningWork: []), kept: 0 ..< 2)
    #expect(compacted.environment.tools.deliveredContext.isEmpty)
    #expect(compacted.environment.tools.folderRoots.isEmpty)
    #expect(compacted.items.dropFirst() == original.items[...])
    let fresh = ScopeContext(folders: ["machines://m2/repo": "machines://m2/repo"], deliveredContext: ["hash": "fresh/AGENTS.md"], text: "manual")
    var next = compacted
    next.items.append(.notification(fresh.notice(id: UUID(), at: Fix.instant)))
    #expect(next.environment.tools.deliveredContext == ["hash": "fresh/AGENTS.md"])
  }

  @Test func `cancellation supersedes subscriptions`() {
    let folded = state([
      Fix.result(.observe(.init(subscriptionID: .init("obs-1"), source: .query("select 1")))),
      Fix.result(.timer(.init(subscriptionID: .init("tim-1"), schedule: .oneShot(Fix.instant), message: "wake"))),
      Fix.result(.cancelObservation(.init(subscriptionID: .init("obs-1")))),
      Fix.result(.cancelTimer(.init(subscriptionID: .init("tim-1")))),
    ])
    #expect(folded.subscriptions.isEmpty)
  }

  @Test func `one-shot timer firing ends its subscription`() {
    let folded = state([
      Fix.result(.timer(.init(subscriptionID: .init("tim-1"), schedule: .oneShot(Fix.instant), message: "wake"))),
      Fix.notification(kind: .timer, subscription: "tim-1", endsSubscription: true),
    ])
    #expect(folded.subscriptions.isEmpty)
  }

  @Test func `messages and posts leave the tool-execution fold untouched`() {
    let folded = state([
      Fix.result(.timer(.init(subscriptionID: .init("tim-1"), schedule: .cron("* * * * *"), message: "wake"))),
      Fix.message(id: "m1"),
      Fix.post(id: "p1"),
    ])
    #expect(folded.subscriptions == [SubscriptionID("tim-1"): .timer(.cron("* * * * *"))])
  }

  @Test func `file access log records the newest revision per path`() {
    let folded = state([
      Fix.result(.read(.init(path: "space://a.md", revision: .journal(3), content: "x"))),
      Fix.result(.write(.init(path: "space://a.md", revision: .journal(4)))),
      Fix.result(.edit(.init(path: "machines://m1/b.txt", revision: .mtime(Fix.instant)))),
    ])
    #expect(folded.fileAccessLog == [
      "space://a.md": .journal(4),
      "machines://m1/b.txt": .mtime(Fix.instant),
    ])
  }

  @Test func `context notices accumulate folder roots and legacy mounts fold as nothing`() {
    let folded = state([
      Fix.result(.read(.init(path: "machines://m1/repo/a.txt", revision: .mtime(Fix.instant), content: "x"))),
      Fix.context(["machines://m1/repo": "machines://m1/repo"], text: "repo manual"),
      Fix.result(.mount(.init(mount: .init(location: "machines://m1"), contextVersion: 1, contextEmission: "m1 ctx"))),
      Fix.context(["machines://m1/tmp": nil]),
    ])
    let expected: [String: String?] = ["machines://m1/repo": "machines://m1/repo", "machines://m1/tmp": nil]
    #expect(folded.folderRoots == expected)
  }

  @Test func `generation head resets the fold to its snapshot`() {
    let snapshot = StateSnapshot(
      subscriptions: [SubscriptionID("tim-1"): .timer(.cron("* * * * *"))],
      preReads: ["space://a.md"],
    )
    let folded = state([
      Fix.result(.read(.init(path: "machines://m1/repo/stale.md", revision: .journal(1), content: "x"))),
      Fix.context(["machines://m1/repo": "machines://m1/repo"], text: "repo manual"),
      .generationHead(.init(id: UUID(), timestamp: Fix.instant, summary: "s", snapshot: snapshot, runningWork: [])),
    ])
    #expect(folded.subscriptions == snapshot.subscriptions)
    #expect(folded.fileAccessLog.isEmpty)
    #expect(folded.folderRoots.isEmpty)
  }
}
