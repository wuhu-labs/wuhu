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
    var params: [[String: Any]] = []

    var i = 0
    while i < context.messages.count {
      let message = context.messages[i]

      switch message {
      case let .user(m):
        let text = m.content.compactMap { block -> String? in
          if case let .text(part) = block { return part.text }
          return nil
        }.joined(separator: "\n")

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          i += 1
          continue
        }

        params.append([
          "role": "user",
          "content": [
            [
              "type": "text",
              "text": text,
            ],
          ],
        ])
        i += 1

      case let .assistant(m):
        var blocks: [[String: Any]] = []
        for block in m.content {
          switch block {
          case let .text(part):
            if part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            blocks.append([
              "type": "text",
              "text": part.text,
            ])
          case let .toolCall(call):
            blocks.append([
              "type": "tool_use",
              "id": call.id,
              "name": call.name,
              "input": call.arguments.toAny(),
            ])
          }
        }
        if !blocks.isEmpty {
          params.append([
            "role": "assistant",
            "content": blocks,
          ])
        }
        i += 1

      case .toolResult:
        var toolResults: [[String: Any]] = []
        while i < context.messages.count {
          guard case let .toolResult(m) = context.messages[i] else { break }

          let text = m.content.compactMap { block -> String? in
            if case let .text(part) = block { return part.text }
            return nil
          }.joined(separator: "\n")

          toolResults.append([
            "type": "tool_result",
            "tool_use_id": m.toolCallId,
            "content": text.isEmpty ? "(no output)" : text,
            "is_error": m.isError,
          ])
          i += 1
        }

        if !toolResults.isEmpty {
          params.append([
            "role": "user",
            "content": toolResults,
          ])
        }
      }
    }

    var body: [String: Any] = [
      "model": model.id,
      "stream": true,
      "messages": params,
      "max_tokens": options.maxTokens ?? 1024,
    ]

    if let system = context.systemPrompt, !system.isEmpty {
      body["system"] = system
    }
    if let temperature = options.temperature {
      body["temperature"] = temperature
    }

    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.parameters.toAny(),
        ] as [String: Any]
      }
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

        var currentTextIndex: Int?
        var currentToolCallIndex: Int?
        var currentToolCallArgumentsBuffer = ""

        do {
          for try await message in sse {
            guard let event = message.event else { continue }
            guard let dict = try parseJSON(message.data) else { continue }

            switch event {
            case "content_block_start":
              if let block = dict["content_block"] as? [String: Any],
                 let type = block["type"] as? String
              {
                if type == "text" {
                  output.content.append(.text(.init(text: "")))
                  currentTextIndex = output.content.count - 1
                  currentToolCallIndex = nil
                  currentToolCallArgumentsBuffer = ""
                } else if type == "tool_use" {
                  let id = block["id"] as? String ?? UUID().uuidString
                  let name = block["name"] as? String ?? "tool"
                  let inputAny = block["input"] ?? [:]
                  let args = (try? JSONValue.fromAny(inputAny)) ?? .object([:])
                  output.content.append(.toolCall(.init(id: id, name: name, arguments: args)))
                  currentToolCallIndex = output.content.count - 1
                  currentTextIndex = nil
                  currentToolCallArgumentsBuffer = ""
                }
              }

            case "content_block_delta":
              if let delta = dict["delta"] as? [String: Any],
                 let deltaType = delta["type"] as? String
              {
                if deltaType == "text_delta", let text = delta["text"] as? String {
                  if let idx = currentTextIndex,
                     idx >= 0,
                     idx < output.content.count,
                     case var .text(part) = output.content[idx]
                  {
                    part.text += text
                    output.content[idx] = .text(part)
                  } else {
                    applyTextDelta(text, to: &output)
                  }
                  continuation.yield(.textDelta(delta: text, partial: output))
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                  currentToolCallArgumentsBuffer += partial
                }
              }

            case "content_block_stop":
              if let idx = currentToolCallIndex,
                 !currentToolCallArgumentsBuffer.isEmpty,
                 idx >= 0,
                 idx < output.content.count,
                 case let .toolCall(existing) = output.content[idx]
              {
                let args = parseJSONValueLenient(currentToolCallArgumentsBuffer) ?? existing.arguments
                output.content[idx] = .toolCall(.init(id: existing.id, name: existing.name, arguments: args))
              }
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentToolCallArgumentsBuffer = ""

            case "message_delta":
              if let delta = dict["delta"] as? [String: Any],
                 let stopReason = delta["stop_reason"] as? String
              {
                output.stopReason = mapAnthropicStopReason(stopReason)
              }

            case "message_stop":
              if output.stopReason == .stop,
                 output.content.contains(where: { if case .toolCall = $0 { true } else { false } })
              {
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
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
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

private func mapAnthropicStopReason(_ reason: String) -> StopReason {
  switch reason {
  case "end_turn":
    .stop
  case "max_tokens":
    .length
  case "tool_use":
    .toolUse
  case "refusal", "sensitive":
    .error
  case "pause_turn", "stop_sequence":
    .stop
  default:
    .stop
  }
}
