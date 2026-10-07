import Foundation
import JSONValue
import Testing
import WuhuAI
import WuhuRecordReplay

@Suite struct CodexHostedHistoryTests {
  @Test(arguments: [false, true])
  func legacySearchContinuesWithoutHostedTool(withFunctionTool: Bool) async throws {
    let recording = withFunctionTool
      ? "codex-legacy-search-function-tool"
      : "codex-legacy-search-no-tools"
    var searchAction: String = #"{"type":"search","queries":["example.com"]}"#
    if withFunctionTool {
      searchAction = #"{"type":"search","queries":["example.com"],"sources":[{"type":"url","url":"https://example.com/"}]}"#
    }
    var history: [ContentBlock] = [
      .hostedTool(try hostedItem(id: "ws_legacy_search", action: searchAction)),
    ]
    if withFunctionTool {
      history.append(.hostedTool(try hostedItem(
        id: "ws_legacy_open",
        action: #"{"type":"open_page","url":"https://example.com/"}"#,
      )))
      history.append(.hostedTool(try hostedItem(
        id: "ws_legacy_find",
        action: #"{"type":"find_in_page","url":"https://example.com/","pattern":"Example"}"#,
      )))
    }
    history.append(.text("Example Domain. \u{e200}cite\u{e202}turn0search0\u{e201}"))
    let tools: [Tool]? = withFunctionTool ? [Tool(
      name: "run_script",
      description: "Run a script using Wuhu's webSearch when search is needed.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["source": .object(["type": .string("string")])]),
        "required": .array([.string("source")]),
      ]),
    )] : nil
    let context = Context(
      systemPrompt: "Follow the latest user instruction.",
      messages: [
        .user(.init(content: [.text("Search for example.com.")])),
        .assistant(.init(content: history)),
        .user(.init(content: [.text("Reply with only OK. Do not search.")])),
      ],
      tools: tools,
    )

    try await withRecording(recording) {
      let endpoint = OpenAICodexEndpoint(
        model: "gpt-6.1-sol",
        baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
        jwt: "",
        originator: "codex_cli_rs",
      )
      let reply = try await endpoint.collectFull(
        context: context,
        options: RequestOptions(reasoning: .none),
      )
      #expect(reply.message.content.compactMap { block in
        if case let .text(text) = block { return text.text }
        return nil
      }.joined() == "OK")
      #expect(reply.message.content.allSatisfy { block in
        if case .text = block { return true }
        return false
      })
      #expect(reply.metadata.usage?.totalTokens == (withFunctionTool ? 203 : 91))
    }
  }
}

private func hostedItem(id: String, action: String) throws -> HostedToolContent {
  let payload = try #require(JSONValue.parse("""
  {"id":"\(id)","type":"web_search_call","status":"completed","action":\(action)}
  """))
  return try #require(HostedToolContent(providerID: "openai-codex", payload: payload))
}
