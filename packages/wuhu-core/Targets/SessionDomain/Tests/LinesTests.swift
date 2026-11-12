#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite struct LinesTests {
  private func user(_ key: String, text: String = "notice") -> TranscriptLine {
    .init(at: Fix.instant, key: key, message: .user(.init(content: [.text(text)])))
  }

  @Test func perItemKeysTimestampsAndReplyMetadataAreStable() throws {
    let message = try #require(Fix.message(id: "message-id").lines(session: Fix.session).first)
    #expect(message.key == "message:message-id")
    #expect(message.at == Fix.instant)
    #expect(message.role == .user)
    #expect(message.meta == nil)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let entry = AssistantEntry(id: id, timestamp: Fix.instant, content: [.text("reply")], stopReason: .stop, usage: .init(inputTokens: 10, outputTokens: 5, totalTokens: 15), toolCallIDs: [:])
    let reply = try #require(TranscriptItem.assistant(entry).lines(session: Fix.session).first)
    #expect(reply.key == "attempt:00000000-0000-0000-0000-000000000012")
    #expect(reply.at == Fix.instant)
    #expect(reply.role == .assistant)
    #expect(reply.meta == .init(stopReason: .stop, usage: entry.usage))
    #expect(try JSONDecoder().decode(TranscriptLine.self, from: JSONEncoder().encode(reply)) == reply)
  }

  @Test func ordinaryCarryRemovesOnlyInferenceMetadata() throws {
    let original = try #require(Fix.assistant(totalTokens: 500).lines(session: Fix.session).first)
    let carried = try #require(original.carried(portable: false))
    #expect(carried.at == original.at)
    #expect(carried.key == original.key)
    #expect(carried.message == original.message)
    #expect(carried.meta == nil)
    #expect(original.meta?.usage.totalTokens == 500)
  }

  @Test func portableProjectionKeepsReadableContentCallsAndReceiptsWithoutAccountRecords() throws {
    let hosted = try #require(HostedToolContent(providerID: "codex", payload: .object([
      "id": .string("ws_1"), "type": .string("web_search_call"), "status": .string("completed"),
      "action": .object(["type": .string("search"), "queries": .array([.string("swift")])]),
    ]), replayScope: "old-account"))
    let call = ToolCall(id: "kernel-call", name: "read", arguments: .object(["path": .string("/a.md")]))
    let content: [ContentBlock] = [
      .reasoning(.encrypted(.init(providerID: "anthropic", model: "m", summary: "readable summary", opaque: "private-signature", replayScope: "old-account"))),
      .reasoning(.encrypted(.init(providerID: "anthropic", model: "m", opaque: "redacted-secret", redacted: true))),
      .reasoning(.encrypted(.init(providerID: "openai", model: "m", opaque: "opaque-only"))),
      .reasoning(.unencrypted("plain reasoning")),
      .text("working"), .hostedTool(hosted), .toolCall(call),
    ]
    let original = TranscriptLine(at: Fix.instant, key: "attempt:reply", message: .assistant(.init(content: content)), meta: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2)))
    let carried = try #require(original.carried(portable: true))
    #expect(carried.message == .assistant(.init(content: [.text("readable summary"), .reasoning(.unencrypted("plain reasoning")), .text("working"), .text(hosted.digest), .toolCall(call)])))
    #expect(carried.meta == nil)
    #expect(original.message.assistant?.content == content)
    let receipt = try #require(Fix.result(.failure(.init(message: "receipt")), provenance: .toolCall(.init(call.id))).lines(session: Fix.session).first)
    #expect(receipt.carried(portable: true) == receipt)
    #expect(user("message:brief").message.portable == user("message:brief").message)
    let encoded = String(decoding: try JSONEncoder().encode(carried), as: UTF8.self)
    #expect(!encoded.contains("private-signature"))
    #expect(!encoded.contains("redacted-secret"))
    #expect(!encoded.contains("opaque-only"))
  }

  @Test func portableCarryDropsAnAssistantWithNoReadableContent() {
    let line = TranscriptLine(at: Fix.instant, key: "attempt:opaque", message: .assistant(.init(content: [.reasoning(.encrypted(.init(providerID: "openai", model: "m", opaque: "secret")))])))
    #expect(line.carried(portable: true) == nil)
    #expect(line.carried(portable: false) == line)
  }

  @Test func callsAreFoundByKernelIDAndReplyLinePosition() throws {
    let call = ToolCall(id: "kernel", name: "compact", arguments: .object(["summary": .string("folded")]))
    let lines = [user("message:input")] + Fix.assistant(totalTokens: 10, toolCalls: [call]).lines(session: Fix.session)
    let found = try #require(lines.toolCall(.init("kernel")))
    #expect(found.index == 1)
    #expect(found.call == call)
    #expect(lines.toolCall(.init("missing")) == nil)
  }

  @Test func bookmarkKeepSkipsFoldedReceiptsImagesAndScopeButNotNewInput() {
    let bookmark = TranscriptItem.bookmark(.init(id: UUID(), timestamp: Fix.instant, name: "keep", toolCallID: .init("bookmark"))).lines(session: Fix.session)
    let receipt = Fix.result(.failure(.init(message: "old receipt"))).lines(session: Fix.session)
    let lines = bookmark + receipt + [user("call:read:image"), user(LineKey.scope), user("message:kept")] + Fix.assistant(totalTokens: 10, toolCalls: [.init(id: "compact", name: "compact", arguments: .object([:]))]).lines(session: Fix.session)
    #expect(lines.keptRange(after: 0, upTo: 5) == 4 ..< 5)
    #expect(lines.keptRange(after: 0, upTo: 4) == nil)
    #expect(lines.keptRange(after: 4, upTo: 5) == nil)
    #expect(lines[0].key == "call:bookmark")
    #expect(lines[0].message.toolResult?.content == [.text("bookmark recorded: keep")])
  }

  @Test func pressureNoticeIsPendingOnlyUntilAReplyOrGenerationHead() {
    let pressure = user(LineKey.pressure)
    #expect([pressure, user(LineKey.scope)].hasPendingPressureNotice)
    #expect(!([pressure] + Fix.assistant(totalTokens: 1).lines(session: Fix.session)).hasPendingPressureNotice)
    #expect(![pressure, user(LineKey.head)].hasPendingPressureNotice)
    #expect(![TranscriptLine]().hasPendingPressureNotice)
  }
}
