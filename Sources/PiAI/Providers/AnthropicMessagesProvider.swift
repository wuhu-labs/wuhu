import Foundation

public struct AnthropicMessagesProvider: Sendable {
  private let http: any HTTPClient

  public init(http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.http = http
  }

  public func stream(model: Model, context: Context, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    guard model.provider == .anthropic else { throw PiAIError.unsupported("Expected provider anthropic") }

    let apiKey = try resolveAPIKey(options.apiKey, env: "ANTHROPIC_API_KEY", provider: model.provider)
    let url = model.baseURL.appending(path: "messages")

    var request = HTTPRequest(url: url, method: "POST")
    request.setHeader(apiKey, for: "x-api-key")
    request.setHeader("application/json", for: "Content-Type")
    request.setHeader("text/event-stream", for: "Accept")
    request.setHeader("2023-06-01", for: "anthropic-version")
    for (k, v) in options.headers {
      request.setHeader(v, for: k)
    }

    let body = try JSONSerialization.data(withJSONObject: buildBody(model: model, context: context, options: options))
    request.body = body

    let sse = try await http.sse(for: request)
    return mapAnthropicSSE(sse, provider: model.provider, modelId: model.id)
  }

  private func buildBody(model: Model, context: Context, options: RequestOptions) -> [String: Any] {
    var messages: [[String: Any]] = []
    for message in context.messages {
      messages.append([
        "role": message.role == .user ? "user" : "assistant",
        "content": message.content,
      ])
    }

    var body: [String: Any] = [
      "model": model.id,
      "stream": true,
      "messages": messages,
      "max_tokens": options.maxTokens ?? 1024,
    ]

    if let system = context.systemPrompt, !system.isEmpty {
      body["system"] = system
    }
    if let temperature = options.temperature {
      body["temperature"] = temperature
    }

    return body
  }

  private func mapAnthropicSSE(
    _ sse: AsyncThrowingStream<SSEMessage, any Error>,
    provider: Provider,
    modelId: String,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var output = AssistantMessage(provider: provider, model: modelId)
        continuation.yield(.start(partial: output))

        do {
          for try await message in sse {
            guard let event = message.event else { continue }
            guard let dict = try parseJSON(message.data) else { continue }

            switch event {
            case "content_block_delta":
              if let delta = dict["delta"] as? [String: Any],
                 (delta["type"] as? String) == "text_delta",
                 let text = delta["text"] as? String
              {
                applyTextDelta(text, to: &output)
                continuation.yield(.textDelta(delta: text, partial: output))
              }

            case "message_stop":
              output.stopReason = .stop

            default:
              continue
            }
          }

          continuation.yield(.done(message: output))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
