import Foundation

public struct AnthropicMessagesProvider: Sendable {
  private let http: any HTTPClient

  public init(http: any HTTPClient = AsyncHTTPClientTransport()) {
    self.http = http
  }

  public func stream(model: Model, context: SimpleContext, options: RequestOptions = .init()) async throws
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

  private func buildBody(model: Model, context: SimpleContext, options: RequestOptions) -> [String: Any] {
    var messages: [[String: Any]] = []

    for message in context.messages {
      switch message {
      case let .user(user):
        messages.append([
          "role": "user",
          "content": user.content,
        ])

      case let .assistant(assistant):
        var blocks: [[String: Any]] = []
        for part in assistant.content {
          switch part {
          case let .text(text):
            blocks.append(["type": "text", "text": text.text])
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
          messages.append([
            "role": "assistant",
            "content": blocks,
          ])
        }

      case let .toolResult(result):
        let contentText = result.content
        messages.append([
          "role": "user",
          "content": [
            [
              "type": "tool_result",
              "tool_use_id": result.toolCallId,
              "content": contentText,
              "is_error": result.isError,
            ],
          ],
        ])
      }
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
    if let tools = context.tools, !tools.isEmpty {
      body["tools"] = tools.map { tool in
        [
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.parameters.toAny(),
        ]
      }
    }

    return body
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

        struct Block {
          var type: String
          var text: String
          var toolCallId: String
          var toolName: String
          var initialArguments: JSONValue?
          var partialJSON: String
        }
        var blocksByIndex: [Int: Block] = [:]

        do {
          for try await message in sse {
            guard let event = message.event else { continue }
            guard let dict = try parseJSON(message.data) else { continue }

            switch event {
            case "content_block_start":
              guard let index = dict["index"] as? Int,
                    let contentBlock = dict["content_block"] as? [String: Any],
                    let blockType = contentBlock["type"] as? String
              else { continue }

              if blockType == "text" {
                blocksByIndex[index] = .init(
                  type: "text",
                  text: "",
                  toolCallId: "",
                  toolName: "",
                  initialArguments: nil,
                  partialJSON: "",
                )
              } else if blockType == "tool_use" {
                let id = contentBlock["id"] as? String ?? ""
                let name = contentBlock["name"] as? String ?? ""
                let initialArgs: JSONValue? = {
                  guard let input = contentBlock["input"] else { return nil }
                  return try? JSONValue(input)
                }()
                blocksByIndex[index] = .init(
                  type: "tool_use",
                  text: "",
                  toolCallId: id,
                  toolName: name,
                  initialArguments: initialArgs,
                  partialJSON: "",
                )
              }

            case "content_block_delta":
              let index = dict["index"] as? Int ?? 0
              guard let delta = dict["delta"] as? [String: Any],
                    let deltaType = delta["type"] as? String
              else { continue }

              if deltaType == "text_delta", let text = delta["text"] as? String {
                applyTextDelta(text, to: &output)
                continuation.yield(.textDelta(delta: text, partial: output))
                if var b = blocksByIndex[index] {
                  b.text += text
                  blocksByIndex[index] = b
                }
              } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                if var b = blocksByIndex[index] {
                  b.partialJSON += partial
                  blocksByIndex[index] = b
                }
              }

            case "content_block_stop":
              guard let index = dict["index"] as? Int,
                    let b = blocksByIndex[index]
              else { continue }
              if b.type == "tool_use" {
                let args: JSONValue = {
                  if !b.partialJSON.isEmpty,
                     let any = try? JSONSerialization.jsonObject(with: Data(b.partialJSON.utf8)),
                     let v = try? JSONValue(any)
                  {
                    return v
                  }
                  return b.initialArguments ?? .object([:])
                }()
                output.content.append(.toolCall(.init(id: b.toolCallId, name: b.toolName, arguments: args)))
              }

            case "message_delta":
              if let delta = dict["delta"] as? [String: Any],
                 let stop = delta["stop_reason"] as? String
              {
                output.stopReason = mapAnthropicStopReason(stop)
              }

            case "message_stop":
              // stopReason already set via message_delta when present.
              if output.stopReason == .stop,
                 output.content.contains(where: { if case .toolCall = $0 { true } else { false } })
              {
                output.stopReason = .toolUse
              }

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

private func mapAnthropicStopReason(_ stopReason: String) -> StopReason {
  switch stopReason {
  case "end_turn":
    .stop
  case "max_tokens":
    .length
  case "tool_use":
    .toolUse
  default:
    .stop
  }
}
