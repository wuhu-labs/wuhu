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
      input.append([
        "role": "system",
        "content": system,
      ])
    }

    var msgIndex = 0
    for message in context.messages {
      switch message {
      case let .user(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        input.append([
          "role": "user",
          "content": [
            [
              "type": "input_text",
              "text": text,
            ],
          ],
        ])

      case let .assistant(m):
        for block in m.content {
          switch block {
          case let .text(part):
            let id = normalizeOpenAIItemId(part.signature ?? "msg_\(msgIndex)")
            input.append([
              "type": "message",
              "role": "assistant",
              "content": [
                [
                  "type": "output_text",
                  "text": part.text,
                  "annotations": [],
                ],
              ],
              "status": "completed",
              "id": id,
            ])
            msgIndex += 1

          case let .toolCall(call):
            let (callId, itemId) = splitToolCallId(call.id)
            var obj: [String: Any] = [
              "type": "function_call",
              "call_id": callId,
              "name": call.name,
              "arguments": jsonString(call.arguments),
            ]
            if let itemId {
              obj["id"] = itemId
            }
            input.append(obj)
          }
        }

      case let .toolResult(m):
        let outputText = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")

        let (callId, _) = splitToolCallId(m.toolCallId)
        input.append([
          "type": "function_call_output",
          "call_id": callId,
          "output": outputText.isEmpty ? "(no output)" : outputText,
        ])
      }
    }

    var body: [String: Any] = [
      "model": model.id,
      "input": input,
      "stream": true,
      "store": false,
    ]

    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "type": "function",
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.parameters.toAny(),
          "strict": false,
        ] as [String: Any]
      }
    }

    if let temperature = options.temperature {
      body["temperature"] = temperature
    }
    if let maxTokens = options.maxTokens {
      body["max_output_tokens"] = maxTokens
    }
    if let sessionId = options.sessionId {
      body["prompt_cache_key"] = sessionId
    }

    if let effort = options.reasoningEffort?.rawValue {
      body["reasoning"] = [
        "effort": effort,
      ]
      body["include"] = ["reasoning.encrypted_content"]
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

        var currentTextIndex: Int?
        var currentToolCallIndex: Int?
        var currentToolCallId: String?
        var currentToolCallName: String?
        var currentToolCallArgumentsBuffer = ""

        do {
          for try await message in sse {
            guard let dict = try parseJSON(message.data) else { continue }
            guard let type = dict["type"] as? String else { continue }

            switch type {
            case "response.output_item.added":
              guard let item = dict["item"] as? [String: Any],
                    let itemType = item["type"] as? String
              else { continue }

              if itemType == "message" {
                output.content.append(.text(.init(text: "")))
                currentTextIndex = output.content.count - 1
                currentToolCallIndex = nil
                currentToolCallId = nil
                currentToolCallName = nil
                currentToolCallArgumentsBuffer = ""
              } else if itemType == "function_call" {
                let callId = item["call_id"] as? String ?? UUID().uuidString
                let itemId = item["id"] as? String
                let name = item["name"] as? String ?? "tool"

                let fullId = itemId.map { "\(callId)|\($0)" } ?? callId
                output.content.append(.toolCall(.init(id: fullId, name: name, arguments: .object([:]))))
                currentToolCallIndex = output.content.count - 1
                currentToolCallId = fullId
                currentToolCallName = name
                currentToolCallArgumentsBuffer = item["arguments"] as? String ?? ""
                currentTextIndex = nil
              }

            case "response.output_text.delta":
              guard let delta = dict["delta"] as? String else { continue }
              if let idx = currentTextIndex,
                 idx >= 0,
                 idx < output.content.count,
                 case var .text(part) = output.content[idx]
              {
                part.text += delta
                output.content[idx] = .text(part)
              } else {
                applyTextDelta(delta, to: &output)
              }
              continuation.yield(.textDelta(delta: delta, partial: output))

            case "response.function_call_arguments.delta":
              guard let delta = dict["delta"] as? String else { continue }
              guard currentToolCallIndex != nil else { continue }
              currentToolCallArgumentsBuffer += delta

            case "response.function_call_arguments.done":
              if let arguments = dict["arguments"] as? String, !arguments.isEmpty {
                currentToolCallArgumentsBuffer = arguments
              }

            case "response.output_item.done":
              guard let item = dict["item"] as? [String: Any],
                    let itemType = item["type"] as? String
              else { continue }

              if itemType == "message" {
                currentTextIndex = nil
              } else if itemType == "function_call" {
                let argsText = (currentToolCallArgumentsBuffer.isEmpty ? (item["arguments"] as? String) : currentToolCallArgumentsBuffer) ?? ""
                if let idx = currentToolCallIndex,
                   idx >= 0,
                   idx < output.content.count,
                   let id = currentToolCallId,
                   let name = currentToolCallName
                {
                  let args = parseJSONValueLenient(argsText) ?? .object([:])
                  output.content[idx] = .toolCall(.init(id: id, name: name, arguments: args))
                }
                currentToolCallIndex = nil
                currentToolCallId = nil
                currentToolCallName = nil
                currentToolCallArgumentsBuffer = ""
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
              if let response = dict["response"] as? [String: Any],
                 let status = response["status"] as? String
              {
                output.stopReason = mapOpenAIResponsesStopReason(status)
              }
              if output.content.contains(where: { if case .toolCall = $0 { true } else { false } }) {
                output.stopReason = .toolUse
              }

            default:
              continue
            }
          }

          if output.stopReason == .stop,
             output.content.contains(where: { if case .toolCall = $0 { true } else { false } })
          {
            output.stopReason = .toolUse
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

private func splitToolCallId(_ id: String) -> (callId: String, itemId: String?) {
  let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
  if parts.count == 2 {
    return (String(parts[0]), String(parts[1]))
  }
  return (id, nil)
}

private func jsonString(_ value: JSONValue) -> String {
  if case let .string(s) = value { return s }
  if let data = try? JSONSerialization.data(withJSONObject: value.toAny()),
     let text = String(data: data, encoding: .utf8)
  {
    return text
  }
  return "{}"
}

private func parseJSONValueLenient(_ text: String) -> JSONValue? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard let data = trimmed.data(using: .utf8) else { return nil }
  do {
    let any = try JSONSerialization.jsonObject(with: data)
    return try JSONValue.fromAny(any)
  } catch {
    return nil
  }
}

private func normalizeOpenAIItemId(_ raw: String) -> String {
  if raw.count <= 64 { return raw }
  return String(raw.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

private func mapOpenAIResponsesStopReason(_ status: String) -> StopReason {
  switch status {
  case "completed":
    .stop
  case "incomplete":
    .length
  case "failed", "cancelled":
    .error
  case "in_progress", "queued":
    .stop
  default:
    .stop
  }
}
