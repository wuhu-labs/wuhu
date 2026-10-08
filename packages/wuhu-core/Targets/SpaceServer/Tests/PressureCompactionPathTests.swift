#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceServer
import Testing
import WuhuAI

@Suite struct PressureCompactionPathTests {
  @Test(arguments: [false, true])
  func modelBookmarkAndMechanicalCompactionDropRetainedPressure(mechanical: Bool) async throws {
    let timestamp = Date(timeIntervalSince1970: 0)
    let sid = SessionID("pressure-compaction")
    let pressure = TranscriptItem.notification(.init(id: UUID(), timestamp: timestamp, kind: .context, subscriptionID: .init("context-pressure"), content: .init(text: "<compaction-notice>Context is 86% full. Compact now.</compaction-notice>")))
    let context = TranscriptItem.notification(.init(id: UUID(), timestamp: timestamp, kind: .context, subscriptionID: .init("context"), content: .init(text: "repository instructions")))
    let message = TranscriptItem.direct(.init(id: UUID(), sender: .init(id: "morgan", timeZone: TimeZone(identifier: "UTC")!), timestamp: timestamp, content: .init(text: "keep this message")))
    var transcript = Transcript(items: [
      .bookmark(.init(id: UUID(), timestamp: timestamp, name: "keep")),
      message,
      context,
      pressure,
    ])
    let kept: Range<Int>?
    if mechanical {
      kept = mechanicalCompaction(of: transcript, images: .claude).kept
    } else {
      transcript.append(.assistant(.init(id: UUID(), timestamp: timestamp, content: [.toolCall(.init(id: "compact", name: "compact", arguments: .object([:])))], stopReason: .stop, usage: .init(inputTokens: 860, outputTokens: 0, totalTokens: 860), toolCallIDs: [:])))
      kept = try transcript.compactKeptRange(callID: .init("compact"), bookmark: "keep")
    }
    let range = try #require(kept)
    #expect(transcript.items[range].contains(pressure))
    let head = GenerationHead(id: UUID(), timestamp: timestamp, summary: "folded", snapshot: .init(subscriptions: [:], preReads: []))
    let compacted = transcript.compacted(head: head, kept: range)
    #expect(!compacted.items.contains(pressure))
    #expect(compacted.items.contains(message))
    #expect(compacted.items.contains(context))
    #expect(compacted.keptCount == compacted.items.count)
    let rendered = await compacted.renderRequest(session: sid, systemPrompt: "sys")
    #expect(!rendered.messages.contains { $0.user?.content.contains { if case let .text(text) = $0 { text.text.contains("86% full") } else { false } } == true })
    #expect(rendered.messages.last?.user?.content.contains { if case let .text(text) = $0 { text.text.contains("repository instructions") } else { false } } == true)
  }
}
