import Foundation
import JSONValue
import Testing
@testable import WuhuAI

// MARK: - CodingKeys Tests

@Suite struct CodingKeysTests {
  // MARK: ContentBlock

  @Test func contentBlockTextRoundTrips() throws {
    let block = ContentBlock.text(TextContent(text: "hello"))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: "thinking...",
      opaque: "sig_abc",
    )))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockRedactedReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: nil,
      opaque: "redacted_data",
      redacted: true,
    )))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
    if case let .reasoning(content) = decoded, case let .encrypted(enc) = content {
      #expect(enc.redacted == true)
      #expect(enc.summary == nil)
      #expect(enc.opaque == "redacted_data")
    } else {
      #expect(Bool(false), "Expected encrypted reasoning with redacted flag")
    }
  }

  @Test func contentBlockUnencryptedReasoningRoundTrips() throws {
    let block = ContentBlock.reasoning(.unencrypted("thinking..."))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockToolCallRoundTrips() throws {
    let block = ContentBlock.toolCall(ToolCall(
      id: "call_123",
      name: "search",
      arguments: .object(["query": .string("hello")]),
    ))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockHostedToolRoundTrips() throws {
    let payload = try #require(JSONValue.parse(#"{ "type":"web_search_call", "action":{ "type":"search" } }"#))
    let item = try #require(HostedToolContent(providerID: "codex", payload: payload))
    let block = ContentBlock.hostedTool(item)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: JSONEncoder().encode(block))
    #expect(decoded == block)
    guard case let .hostedTool(decodedItem) = decoded else { return }
    #expect(decodedItem.payload == payload)
  }

  @Test func toolKindsRoundTrip() throws {
    let tools: [Tool] = [
      Tool(name: "search", description: "Search", parameters: .object(["type": "object"])),
      .hosted(type: "web_search"),
    ]
    #expect(try JSONDecoder().decode([Tool].self, from: JSONEncoder().encode(tools)) == tools)
  }

  @Test func contentBlockMediaRoundTrips() throws {
    let block = ContentBlock.media(MediaContent(
      url: URL(string: "https://example.com/img.png")!,
      mimeType: "image/png",
    ))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func contentBlockUsesSnakeCaseKeys() throws {
    let block = ContentBlock.reasoning(.encrypted(EncryptedReasoningContent(
      providerID: "anthropic",
      model: "claude",
      summary: "think",
      opaque: "sig",
      redacted: false,
    )))
    let data = try JSONEncoder().encode(block)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let reasoning = json["reasoning"] as! [String: Any]
    #expect(reasoning["provider_id"] as? String == "anthropic")
    #expect(reasoning["model"] as? String == "claude")
    #expect(reasoning["summary"] as? String == "think")
    #expect(reasoning["opaque"] as? String == "sig")
    #expect(reasoning["redacted"] as? Bool == false)
  }

  // MARK: Message

  @Test func userMessageRoundTrips() throws {
    let msg = Message.user(UserMessage(
      content: [.text(TextContent(text: "hi"))],
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func assistantMessageRoundTrips() throws {
    let msg = Message.assistant(AssistantMessage(
      content: [.text(TextContent(text: "hello"))],
      phase: .finalAnswer,
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func toolResultMessageRoundTrips() throws {
    let msg = Message.toolResult(ToolResultMessage(
      toolCallId: "call_abc",
      content: [.text(TextContent(text: "result"))],
      isError: false,
    ))
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(Message.self, from: data)
    #expect(decoded == msg)
  }

  @Test func assistantMessageUsesSnakeCaseKeys() throws {
    let msg = AssistantMessage(
      content: [.text(TextContent(text: "hello"))],
      phase: .commentary,
    )
    let data = try JSONEncoder().encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["phase"] as? String == "commentary")
    let content = json["content"] as! [[String: Any]]
    #expect((content[0]["text"] as? [String: Any])?["text"] as? String == "hello")
  }

  // MARK: AssistantMessageMetadata

  @Test func assistantMessageMetadataRoundTrips() throws {
    let metadata = AssistantMessageMetadata(
      stopReason: .maxTokens,
      usage: Usage(
        inputTokens: 10,
        outputTokens: 20,
        cacheReadTokens: 3,
        cacheWriteTokens: 4,
        reasoningTokens: 5,
        totalTokens: 42,
      ),
    )
    let data = try JSONEncoder().encode(metadata)
    let decoded = try JSONDecoder().decode(AssistantMessageMetadata.self, from: data)
    #expect(decoded == metadata)
  }

  @Test func assistantMessageMetadataUsesSnakeCaseKeys() throws {
    let metadata = AssistantMessageMetadata(
      stopReason: .maxTokens,
      usage: Usage(inputTokens: 1, outputTokens: 2, totalTokens: 3),
    )
    let data = try JSONEncoder().encode(metadata)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["stop_reason"] as? String == "max_tokens")
    #expect(json["stopReason"] == nil)
    let usage = json["usage"] as! [String: Any]
    #expect(usage["input_tokens"] as? Int == 1)
    #expect(usage["output_tokens"] as? Int == 2)
    #expect(usage["total_tokens"] as? Int == 3)
  }

  // MARK: AssistantMessagePhase

  @Test func phaseEncodesAsSnakeCase() throws {
    let data = try JSONEncoder().encode(AssistantMessagePhase.finalAnswer)
    let str = String(data: data, encoding: .utf8)!
    #expect(str.contains("final_answer"))
  }
}
