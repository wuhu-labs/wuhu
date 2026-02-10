import Foundation

public struct OpenAIResponsesProvider: Sendable {
  private let http: any HTTPClient

  public init(http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.http = http
  }

  public func stream(model: Model, context: Context, options: RequestOptions = .init()) async throws
    -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  {
    guard model.provider == .openai else { throw PiAIError.unsupported("Expected provider openai") }

    let apiKey = try resolveAPIKey(options.apiKey, env: "OPENAI_API_KEY", provider: model.provider)

    let url = model.baseURL.appending(path: "responses")
    var request = HTTPRequest(url: url, method: "POST")
    request.setHeader("Bearer \(apiKey)", for: "Authorization")
    request.setHeader("application/json", for: "Content-Type")
    request.setHeader("text/event-stream", for: "Accept")
    for (k, v) in options.headers {
      request.setHeader(v, for: k)
    }

    let body = try JSONSerialization.data(withJSONObject: buildBody(model: model, context: context, options: options))
    request.body = body

    let sse = try await http.sse(for: request)
    return mapResponsesSSE(sse, provider: model.provider, modelId: model.id)
  }

  private func buildBody(model: Model, context: Context, options: RequestOptions) -> [String: Any] {
    var input: [[String: Any]] = []
    if let system = context.systemPrompt, !system.isEmpty {
      input.append(["role": "system", "content": system])
    }
    for message in context.messages {
      input.append(["role": message.role.rawValue, "content": message.content])
    }

    var body: [String: Any] = [
      "model": model.id,
      "input": input,
      "stream": true,
      "store": false,
    ]

    if let temperature = options.temperature {
      body["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
      body["max_output_tokens"] = maxTokens
    }
    if let sessionId = options.sessionId {
      body["prompt_cache_key"] = sessionId
    }

    return body
  }

  private func mapResponsesSSE(
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
            guard let dict = try parseJSON(message.data) else { continue }
            guard let type = dict["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
              guard let delta = dict["delta"] as? String else { continue }
              applyTextDelta(delta, to: &output)
              continuation.yield(.textDelta(delta: delta, partial: output))

            case "response.output_item.done":
              if let item = dict["item"] as? [String: Any],
                 let content = item["content"] as? [[String: Any]]
              {
                let text = content
                  .filter { ($0["type"] as? String) == "output_text" }
                  .compactMap { $0["text"] as? String }
                  .joined()
                if !text.isEmpty {
                  output.content = [.text(.init(text: text))]
                }
              }

            case "response.completed":
              if let response = dict["response"] as? [String: Any],
                 let usage = response["usage"] as? [String: Any]
              {
                let input = usage["input_tokens"] as? Int ?? 0
                let outputTokens = usage["output_tokens"] as? Int ?? 0
                let total = usage["total_tokens"] as? Int ?? (input + outputTokens)
                output.usage = Usage(inputTokens: input, outputTokens: outputTokens, totalTokens: total)
              }

            default:
              continue
            }
          }

          output.stopReason = .stop
          continuation.yield(.done(message: output))
          continuation.finish()
        } catch {
          output.stopReason = .error
          output.errorMessage = String(describing: error)
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
