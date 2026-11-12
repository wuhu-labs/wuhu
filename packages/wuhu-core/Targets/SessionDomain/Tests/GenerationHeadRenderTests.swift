#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing

@Suite struct GenerationHeadRenderTests {
  @Test func generationHeadSurvivesLiveChangesAndReloadAsAnExactPrefix() throws {
    let timer = SubscriptionID("timer.old")
    let head = GenerationHead(
      id: UUID(), timestamp: Fix.instant, summary: "summary",
      snapshot: .init(subscriptions: [timer: .timer(.oneShot(Fix.instant))], preReads: ["/keep.md"]),
      runningWork: ["script.started", "exec.started"],
    )
    func message(handle: String, device: String) -> TranscriptItem {
      guard case var .message(message) = Fix.message(sender: "alice") else { preconditionFailure() }
      message.sender = .init(id: "alice", timeZone: message.sender.timeZone, device: "phone", handle: handle, deviceName: device)
      return .message(message)
    }
    var lines = head.lines(session: Fix.session) + message(handle: "old", device: "Old Phone").lines(session: Fix.session)
    let first = lines.map(\.message)
    lines += message(handle: "renamed", device: "New Phone").lines(session: Fix.session)
    let next = lines.map(\.message)
    let reloaded = try JSONDecoder().decode([TranscriptLine].self, from: JSONEncoder().encode(lines))
    let replay = reloaded.map(\.message)
    #expect(Array(next.prefix(first.count)) == first)
    #expect(replay == next)
    #expect(first.last?.user?.content != next.last?.user?.content)
    guard case let .text(text)? = first.first?.user?.content.first else {
      Issue.record("missing snapshot"); return
    }
    #expect(text.text.contains("active subscriptions: timer.old"))
    #expect(text.text.contains("running: exec.started, script.started"))
  }
}
