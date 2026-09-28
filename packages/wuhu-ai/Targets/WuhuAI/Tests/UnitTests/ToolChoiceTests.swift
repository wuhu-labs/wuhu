import Foundation
import JSONValue
import OrderedCollections
import Testing
@testable import WuhuAI

private let echoTool = Tool(
  name: "echo",
  description: "Echoes back the input text.",
  parameters: .object([
    "type": .string("object"),
    "properties": .object(["text": .object(["type": .string("string")])]),
    "required": .array([.string("text")]),
  ]),
)

private let toolContext = Context(
  messages: [.user(.init(content: [.text(.init(text: "Hi"))]))],
  tools: [echoTool],
)

@Suite struct ToolChoiceTests {
  @Test func anthropicOmitsToolChoiceByDefault() async throws {
    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(),
    )
    #expect(body["tool_choice"] == nil)
  }

  @Test func anthropicEmitsNamedForce() async throws {
    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .tool(name: "echo")),
    )
    #expect(body["tool_choice"] == .object(["type": .string("tool"), "name": .string("echo")]))
  }

  @Test func anthropicEmitsAnyForce() async throws {
    let (_, _, body) = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .any),
    )
    #expect(body["tool_choice"] == .object(["type": .string("any")]))
  }

  @Test func anthropicForcingLeavesToolListIntact() async throws {
    let normal = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(),
    )
    let forced = try await buildAnthropicRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .tool(name: "echo")),
    )
    #expect(normal.body["tools"] == forced.body["tools"])
  }

  @Test func responsesEmitsNamedForce() async throws {
    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .tool(name: "echo")),
      isCodex: false,
    )
    #expect(body["tool_choice"] == .object(["type": .string("function"), "name": .string("echo")]))
  }

  @Test func responsesEmitsRequiredForAny() async throws {
    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .any),
      isCodex: false,
    )
    #expect(body["tool_choice"] == .string("required"))
  }

  @Test func responsesKeepsReasoningAlongsideForce() async throws {
    let (_, _, body) = try await buildResponsesRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(reasoning: .effort("high"), toolChoice: .tool(name: "echo")),
      isCodex: false,
    )
    #expect(body["reasoning"]?.object?["effort"] == .string("high"))
    #expect(body["tool_choice"] == .object(["type": .string("function"), "name": .string("echo")]))
  }

  @Test func chatCompletionsEmitsNamedForce() async throws {
    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .tool(name: "echo")),
      mediaResolver: nil,
    )
    #expect(body["tool_choice"] == .object([
      "type": .string("function"),
      "function": .object(["name": .string("echo")]),
    ]))
  }

  @Test func chatCompletionsEmitsRequiredForAny() async throws {
    let (_, _, body) = try await buildChatCompletionsRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .any),
      mediaResolver: nil,
    )
    #expect(body["tool_choice"] == .string("required"))
  }

  @Test func geminiEmitsFunctionCallingConfig() async throws {
    let named = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .tool(name: "echo")),
    )
    #expect(named.body["toolConfig"] == .object([
      "functionCallingConfig": .object([
        "mode": .string("ANY"),
        "allowedFunctionNames": .array([.string("echo")]),
      ]),
    ]))

    let any = try await buildGeminiRequest(
      model: "m",
      baseURL: URL(string: "https://a.com/v1")!,
      context: toolContext,
      options: RequestOptions(toolChoice: .any),
    )
    #expect(any.body["toolConfig"] == .object([
      "functionCallingConfig": .object(["mode": .string("ANY")]),
    ]))
  }
}

@Suite struct ForcingEndpointRecipeTests {
  @Test func anthropicEffortPassesVerbatim() {
    let endpoint = AnthropicEndpoint(model: "claude-sonnet-5", apiKey: "k")
    var body: OrderedDictionary<String, JSONValue> = [:]
    endpoint.modifyBody(&body, options: RequestOptions(reasoning: .effort("xhigh")))
    #expect(body["output_config"] == .object(["effort": .string("xhigh")]))
    #expect(body["thinking"]?.object?["type"] == .string("adaptive"))
  }

  @Test func anthropicKeepsAdaptiveThinkingUnderNamedForce() {
    let endpoint = AnthropicEndpoint(model: "claude-sonnet-5", apiKey: "k")
    var body: OrderedDictionary<String, JSONValue> = [:]
    endpoint.modifyBody(&body, options: RequestOptions(
      reasoning: .effort("high"),
      toolChoice: .tool(name: "compact"),
    ))
    #expect(body["thinking"]?.object?["type"] == .string("adaptive"))
    #expect(body["output_config"] == .object(["effort": .string("high")]))
  }

  @Test func deepSeekAnthropicDisablesThinkingForNamedForceOnly() {
    let endpoint = DeepSeekAnthropicEndpoint(model: "deepseek-v4-pro", apiKey: "k")

    var named: OrderedDictionary<String, JSONValue> = [:]
    endpoint.modifyBody(&named, options: RequestOptions(
      reasoning: .effort("high"),
      toolChoice: .tool(name: "compact"),
    ))
    #expect(named["thinking"] == .object(["type": .string("disabled")]))
    #expect(named["output_config"] == nil)

    var any: OrderedDictionary<String, JSONValue> = [:]
    endpoint.modifyBody(&any, options: RequestOptions(reasoning: .effort("high"), toolChoice: .any))
    #expect(any["thinking"] == .object(["type": .string("enabled")]))
    #expect(any["output_config"] == .object(["effort": .string("high")]))
  }

  @Test func deepSeekChatDisablesThinkingForEveryForcingForm() {
    let endpoint = DeepSeekChatEndpoint(model: "deepseek-v4-pro", apiKey: "k")

    for choice in [ToolChoice.any, .tool(name: "compact")] {
      var body: OrderedDictionary<String, JSONValue> = [:]
      endpoint.modifyBody(&body, options: RequestOptions(reasoning: .effort("high"), toolChoice: choice))
      #expect(body["thinking"] == .object(["type": .string("disabled")]))
      #expect(body["reasoning_effort"] == nil)
    }
  }
}
