import Foundation
import JSONValue
import Testing
@testable import WuhuAI

@Suite struct StructuredOutputTests {
  private let schema: JSONValue = .object([
    "type": .string("object"), "properties": .object(["relevant": .object(["type": .string("boolean")])]),
    "required": .array([.string("relevant")]), "additionalProperties": .bool(false),
  ])
  private let context = Context(messages: [.user(.init(content: [.text("Judge relevance")]))])
  private let base = URL(string: "https://provider.test")!

  @Test(arguments: [false, true]) func responsesAndCodexRequestSchemaWithoutTools(codex: Bool) async throws {
    let options = RequestOptions(reasoning: .none, outputSchema: schema)
    var (_, _, body) = try await buildResponsesRequest(model: "test", baseURL: base, context: context, options: options, isCodex: codex)
    if codex { OpenAICodexEndpoint(model: "test", jwt: "fixture", chatgptAccountID: "account", sessionID: "session").modifyBody(&body, options: options) }
    else { OpenAIGPTEndpoint(model: "test", apiKey: "fixture").modifyBody(&body, options: options) }
    let format = body["text"]?.object?["format"]?.object
    #expect(format?["type"] == .string("json_schema"))
    #expect(format?["schema"] == schema)
    #expect(format?["strict"] == .bool(true))
    #expect(body["tools"] == nil)
  }

  @Test func anthropicSchemaSurvivesReasoningConfiguration() async throws {
    let options = RequestOptions(reasoning: .effort("low"), outputSchema: schema)
    var (_, _, body) = try await buildAnthropicRequest(model: "test", baseURL: base, context: context, options: options)
    AnthropicEndpoint(model: "test", apiKey: "fixture").modifyBody(&body, options: options)
    #expect(body["output_config"]?.object?["effort"] == .string("low"))
    #expect(body["output_config"]?.object?["format"]?.object?["schema"] == schema)
    #expect(body["tools"] == nil)
  }

  @Test func chatCompletionsAndGeminiCarryNativeSchemas() async throws {
    let options = RequestOptions(reasoning: .none, outputSchema: schema)
    let (_, _, chat) = try await buildChatCompletionsRequest(model: "test", baseURL: base, context: context, options: options, mediaResolver: nil)
    #expect(chat["response_format"]?.object?["json_schema"]?.object?["schema"] == schema)
    #expect(chat["response_format"]?.object?["json_schema"]?.object?["strict"] == .bool(true))
    let (_, _, gemini) = try await buildGeminiRequest(model: "test", baseURL: base, context: context, options: options)
    #expect(gemini["generationConfig"]?.object?["responseMimeType"] == .string("application/json"))
    #expect(gemini["generationConfig"]?.object?["responseJsonSchema"] == schema)
    #expect(chat["tools"] == nil)
    #expect(gemini["tools"] == nil)
  }

  @Test func omittedSchemaPreservesOrdinaryRequests() async throws {
    let (_, _, body) = try await buildResponsesRequest(model: "test", baseURL: base, context: context, options: RequestOptions(), isCodex: false)
    #expect(body["text"] == nil)
  }
}
