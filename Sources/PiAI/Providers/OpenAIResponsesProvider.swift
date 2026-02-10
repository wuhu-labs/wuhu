import Foundation

public struct OpenAIResponsesProvider: Sendable {
  private let http: any HTTPClient

  public init(http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.http = http
  }

  public func stream(model: Model, context: SimpleContext, options: RequestOptions = .init()) async throws
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

  private func buildBody(model: Model, context: SimpleContext, options: RequestOptions) -> [String: Any] {
    var input: [[String: Any]] = []
    if let system = context.systemPrompt, !system.isEmpty {
      input.append(["role": "system", "content": system])
    }

    var msgIndex = 0
    for message in context.messages {
      switch message {
      case let .user(user):
        input.append([
          "role": "user",
          "content": [
            ["type": "input_text", "text": user.content],
          ],
        ])

      case let .assistant(assistant):
        for block in assistant.content {
          switch block {
          case let .text(text):
            let id = (text.signature?.isEmpty == false) ? text.signature! : "msg_\(msgIndex)"
            msgIndex += 1
            input.append([
              "type": "message",
              "role": "assistant",
              "status": "completed",
              "id": id,
              "content": [
                ["type": "output_text", "text": text.text],
              ],
            ])

          case let .toolCall(call):
            let (callId, itemId) = splitOpenAIToolCallId(call.id)
            let argsString = (try? jsonString(call.arguments)) ?? "{}"
            input.append([
              "type": "function_call",
              "call_id": callId,
              "id": itemId,
              "name": call.name,
              "arguments": argsString,
            ])
          }
        }

      case let .toolResult(result):
        let (callId, _) = splitOpenAIToolCallId(result.toolCallId)
        input.append([
          "type": "function_call_output",
          "call_id": callId,
          "output": result.content,
        ])
      }
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
    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "type": "function",
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.parameters.toAny(),
        ]
      }
    }

    return body
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
                 let itemType = item["type"] as? String
              {
                if itemType == "message" {
                  if let content = item["content"] as? [[String: Any]] {
                    let text = content
                      .filter { ($0["type"] as? String) == "output_text" }
                      .compactMap { $0["text"] as? String }
                      .joined()
                    if !text.isEmpty {
                      upsertAssistantText(text, into: &output)
                    }
                  }
                } else if itemType == "function_call" {
                  guard let callId = item["call_id"] as? String,
                        let itemId = item["id"] as? String,
                        let name = item["name"] as? String,
                        let argsText = item["arguments"] as? String
                  else { continue }
                  if let argsAny = try? JSONSerialization.jsonObject(with: Data(argsText.utf8)),
                     let args = try? JSONValue(argsAny)
                  {
                    output.content.append(.toolCall(.init(id: "\(callId)|\(itemId)", name: name, arguments: args)))
                  } else {
                    output.content.append(.toolCall(.init(id: "\(callId)|\(itemId)", name: name, arguments: .object([:]))))
                  }
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

            case "response.failed":
              throw PiAIError.httpStatus(code: 500, body: message.data)

            case "error":
              throw PiAIError.httpStatus(code: 500, body: message.data)

            default:
              continue
            }
          }

          if output.content.contains(where: { if case .toolCall = $0 { true } else { false } }) {
            output.stopReason = .toolUse
          } else {
            output.stopReason = .stop
          }
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

private func splitOpenAIToolCallId(_ id: String) -> (callId: String, itemId: String) {
  if let pipe = id.firstIndex(of: "|") {
    let callId = String(id[..<pipe])
    let itemId = String(id[id.index(after: pipe)...])
    return (callId, itemId)
  }
  return (id, "fc_\(id)")
}

private func jsonString(_ value: JSONValue) throws -> String {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return String(decoding: data, as: UTF8.self)
}

private func upsertAssistantText(_ text: String, into message: inout AssistantMessage) {
  for i in message.content.indices {
    if case .text = message.content[i] {
      message.content[i] = .text(.init(text: text))
      return
    }
  }
  message.content.insert(.text(.init(text: text)), at: 0)
}
