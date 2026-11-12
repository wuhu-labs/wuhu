#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite struct AssistantEntryTests {
  @Test func providerCallIDsAreMintedOnceAndEveryOtherBlockIsPreserved() {
    let reasoning = ContentBlock.reasoning(.unencrypted("plan"))
    let calls = ["provider-a", "provider-b"].map { ToolCall(id: $0, name: "read", arguments: .object(["path": .string("/a.md")])) }
    var minted = 0
    let entry = AssistantEntry(
      .init(content: [reasoning, .text("working")] + calls.map(ContentBlock.toolCall)),
      id: UUID(), at: Fix.instant,
      metadata: .init(stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 5, totalTokens: 15)),
      replayBinding: .init(identity: "account", epoch: "route"),
      mint: { minted += 1; return ToolCallID("kernel-\(minted)") },
    )
    #expect(minted == 2)
    #expect(entry.toolCallIDs == ["provider-a": ToolCallID("kernel-1"), "provider-b": ToolCallID("kernel-2")])
    #expect(entry.toolCalls.map(\.id) == ["kernel-1", "kernel-2"])
    #expect(entry.toolCalls.map(\.arguments) == calls.map(\.arguments))
    #expect(Array(entry.content.prefix(2)) == [reasoning, .text("working")])
    #expect(entry.timestamp == Fix.instant)
    #expect(entry.replayBinding == .init(identity: "account", epoch: "route"))
    let lines = TranscriptItem.assistant(entry).lines(session: Fix.session)
    #expect(lines.first?.meta?.usage.totalTokens == 15)
    #expect(lines.estimatedContextTokens(images: .claude) == 15)
  }

  @Test func missingUsageTraps() async {
    await #expect(processExitsWith: .failure) {
      _ = AssistantEntry(.init(content: [.text("done")]), id: UUID(), at: Fix.instant, metadata: .init(stopReason: .stop, usage: nil), replayBinding: nil, mint: { ToolCallID("unused") })
    }
  }

  @Test func duplicateProviderCallIDsTrap() async {
    await #expect(processExitsWith: .failure) {
      let call = ContentBlock.toolCall(.init(id: "duplicate", name: "read", arguments: .object([:])))
      _ = AssistantEntry(.init(content: [call, call]), id: UUID(), at: Fix.instant, metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2)), replayBinding: nil, mint: { ToolCallID(UUID().uuidString) })
    }
  }
}
