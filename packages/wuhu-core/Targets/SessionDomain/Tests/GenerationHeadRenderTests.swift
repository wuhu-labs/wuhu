import Foundation
import SessionDomain
import Testing

@Suite struct GenerationHeadRenderTests {
  @Test func generationHeadSurvivesLiveChangesAndReloadAsAnExactPrefix() async throws {
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
    var transcript = Transcript(items: [.generationHead(head), message(handle: "old", device: "Old Phone")])
    let first = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    transcript.append(message(handle: "renamed", device: "New Phone"))
    let next = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    let reloaded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
    let replay = await reloaded.renderRequest(session: Fix.session, systemPrompt: "sys")
    #expect(Array(next.messages.prefix(first.messages.count)) == first.messages)
    #expect(replay == next)
    #expect(first.messages.last?.user?.content != next.messages.last?.user?.content)
    guard case let .text(text)? = first.messages.first?.user?.content.first else {
      Issue.record("missing snapshot"); return
    }
    #expect(text.text.contains("active subscriptions: timer.old"))
    #expect(text.text.contains("running: exec.started, script.started"))
  }
}
