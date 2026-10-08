import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

// Key order deliberately non-alphabetical, with one insignificant space: these
// are the bytes a provider emitted, and every later request has to carry them
// unchanged or the prompt cache dies at the first tool call of the transcript.
private let emittedArguments = #"{"command":"bash -lc 'ls -la'", "max_output":30000,"timeout_seconds":30}"#

private func sseEvent(_ fields: JSONValue) -> String {
  "data: " + fields.jsonString() + "\n\n"
}

private let functionCallStream = [
  sseEvent(.object([
    "type": .string("response.output_item.added"),
    "item": .object([
      "type": .string("function_call"),
      "call_id": .string("call_1"),
      "name": .string("exec"),
      "arguments": .string(""),
    ]),
  ])),
  sseEvent(.object([
    "type": .string("response.function_call_arguments.delta"),
    "delta": .string(emittedArguments),
  ])),
  sseEvent(.object([
    "type": .string("response.function_call_arguments.done"),
    "arguments": .string(emittedArguments),
  ])),
  sseEvent(.object([
    "type": .string("response.output_item.done"),
    "item": .object([
      "type": .string("function_call"),
      "call_id": .string("call_1"),
      "name": .string("exec"),
      "arguments": .string(emittedArguments),
    ]),
  ])),
  sseEvent(.object([
    "type": .string("response.completed"),
    "response": .object([
      "status": .string("completed"),
      "usage": .object([
        "input_tokens": .integer(10),
        "output_tokens": .integer(5),
        "total_tokens": .integer(15),
      ]),
    ]),
  ])),
].joined()

private struct RequestInterrupted: Error {}

private let endpoint = OpenAIGPTEndpoint(model: "gpt-5.6-luna", apiKey: "test-key")

private func streamedToolCall() async throws -> AssistantMessage {
  let replying = endpoint.withFetch(FetchClient { _ in
    Response(
      status: .ok,
      headers: HTTPFields(),
      body: .bytes(Data(functionCallStream.utf8), contentType: "text/event-stream"),
    )
  })
  return try await replying.inference(context: Context(messages: [])).collect()
}

private func renderedRequestBody(_ store: SessionStore, _ session: SessionID) async throws -> String {
  let bodies = Mutex<[String]>([])
  let capturing = endpoint.withFetch(FetchClient { request in
    let body = try await request.body?.text() ?? ""
    bodies.withLock { $0.append(body) }
    throw RequestInterrupted()
  })
  let transcript = try await store.transcript(session)
  let context = await transcript.renderRequest(
    session: session,
    systemPrompt: "sys",
  )
  _ = try? await capturing.inference(context: context).collect()
  return try #require(bodies.withLock { $0.first })
}

@Suite struct ToolCallWireBytesTests {
  @Test func `a stored tool call renders the bytes the model emitted, every time`() async throws {
    let message = try await streamedToolCall()
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(
      group: .shared,
      title: "caller",
      kind: .agent,
      createdBy: "owner",
      model: ModelSpecifier(provider: "openai", model: "gpt-5.6-luna", effort: "medium"),
    )
    _ = try await space.sessions.appendAssistant(
      session,
      attemptID: UUID(),
      message: message,
      metadata: AssistantMessageMetadata(
        stopReason: .stop,
        usage: Usage(inputTokens: 10, outputTokens: 5, totalTokens: 15),
      ),
    )

    let first = try await renderedRequestBody(space.sessions, session)
    let second = try await renderedRequestBody(space.sessions, session)
    #expect(first == second, "the same transcript must render the same request bytes")

    let input = try #require(JSONValue.parse(first)?.object?["input"]?.array)
    let call = try #require(input.compactMap(\.object).first { $0["type"] == .string("function_call") })
    #expect(call["arguments"]?.stringValue == emittedArguments)
  }
}
