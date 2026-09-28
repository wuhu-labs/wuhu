import Foundation
import JSONValue
import OrderedCollections

// MARK: - Chat Completions Request Builder

/// Build a Chat Completions request body from domain types.
///
/// Wire format: OpenAI-compatible `/v1/chat/completions`, SSE streaming.
func buildChatCompletionsRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
  mediaResolver: (any MediaResolver)?,
) async throws -> (url: URL, headers: [String: String], body: OrderedDictionary<String, JSONValue>) {
  let url = baseURL.appendingPathComponent("chat/completions")

  let headers: [String: String] = [
    "content-type": "application/json",
    "accept": "text/event-stream",
  ]

  var body: OrderedDictionary<String, JSONValue> = [
    "model": .string(model),
    "messages": .array(try await buildMessages(context: context, mediaResolver: mediaResolver)),
    "stream": .bool(true),
  ]

  if let temperature = options.temperature {
    body["temperature"] = .number(temperature)
  }
  if let maxTokens = options.maxTokens {
    body["max_tokens"] = .integer(maxTokens)
  }
  let tools = (context.tools ?? []).compactMap(buildTool)
  if !tools.isEmpty {
    body["tools"] = .array(tools)
  }

  switch options.toolChoice {
  case .none:
    break
  case .any:
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .string("required")
  case let .tool(name):
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .object([
      "type": .string("function"),
      "function": .object(["name": .string(name)]),
    ])
  }

  return (url, headers, body)
}

// MARK: - Messages

private func buildMessages(
  context: Context,
  mediaResolver: (any MediaResolver)?,
) async throws -> [JSONValue] {
  var messages: [JSONValue] = []

  if let system = context.systemPrompt, !system.isEmpty {
    messages.append(.object([
      "role": .string("system"),
      "content": .string(system),
    ]))
  }

  for message in context.messages {
    switch message {
    case let .user(m):
      let content = try await buildUserContent(m.content, mediaResolver: mediaResolver)
      if !content.isEmpty {
        let contentValue: JSONValue = if content.count == 1,
                                         case let .object(obj) = content[0],
                                         obj["type"] == .string("text"),
                                         let text = obj["text"]
        {
          text
        } else {
          .array(content)
        }
        messages.append(.object([
          "role": .string("user"),
          "content": contentValue,
        ]))
      }

    case let .assistant(m):
      var msgObj: OrderedDictionary<String, JSONValue> = [
        "role": .string("assistant"),
      ]

      var contentBlocks: [JSONValue] = []
      var reasoningText = ""
      var toolCalls: [JSONValue] = []

      for block in m.content {
        switch block {
        case let .text(text):
          if !text.text.isEmpty {
            contentBlocks.append(.object([
              "type": .string("text"),
              "text": .string(text.text),
            ]))
          }

        case let .reasoning(reasoning):
          switch reasoning {
          case let .unencrypted(text):
            reasoningText += text
          case let .encrypted(enc):
            if let summary = enc.summary {
              reasoningText += summary
            }
          }

        case let .toolCall(toolCall):
          toolCalls.append(.object([
            "id": .string(toolCall.id),
            "type": .string("function"),
            "function": .object([
              "name": .string(toolCall.name),
              "arguments": .string(toolCall.arguments.text),
            ]),
          ]))

        case .hostedTool, .media:
          // Media output not supported in Chat Completions.
          break
        }
      }

      if !reasoningText.isEmpty {
        msgObj["reasoning_content"] = .string(reasoningText)
      }

      if !contentBlocks.isEmpty || !toolCalls.isEmpty {
        if toolCalls.isEmpty {
          if contentBlocks.count == 1,
             case let .object(obj) = contentBlocks[0],
             obj["type"] == .string("text"),
             let text = obj["text"]
          {
            msgObj["content"] = text
          } else {
            msgObj["content"] = .array(contentBlocks)
          }
        } else {
          if contentBlocks.isEmpty {
            msgObj["content"] = .null
          } else if contentBlocks.count == 1,
                    case let .object(obj) = contentBlocks[0],
                    obj["type"] == .string("text"),
                    let text = obj["text"]
          {
            msgObj["content"] = text
          } else {
            msgObj["content"] = .array(contentBlocks)
          }
          msgObj["tool_calls"] = .array(toolCalls)
        }
      }

      messages.append(.object(msgObj))

    case let .toolResult(m):
      messages.append(.object([
        "role": .string("tool"),
        "tool_call_id": .string(m.toolCallId),
        "content": .string(formatToolResultContent(m.content)),
      ]))
    }
  }

  return messages
}

// MARK: - User Content

private func buildUserContent(
  _ blocks: [ContentBlock],
  mediaResolver: (any MediaResolver)?,
) async throws -> [JSONValue] {
  var parts: [JSONValue] = []

  for block in blocks {
    switch block {
    case let .text(text):
      if !text.text.isEmpty {
        parts.append(.object([
          "type": .string("text"),
          "text": .string(text.text),
        ]))
      }

    case let .media(media):
      if let part = try await buildMediaPart(media, mediaResolver: mediaResolver) {
        parts.append(part)
      } else {
        // SPEC §4.1: insert placeholder text when media can't be rendered
        parts.append(.object([
          "type": .string("text"),
          "text": .string("(content omitted: model does not support this format)"),
        ]))
      }

    case .reasoning, .toolCall, .hostedTool:
      break
    }
  }

  return parts
}

// MARK: - Media

private func buildMediaPart(
  _ media: MediaContent,
  mediaResolver: (any MediaResolver)?,
) async throws -> JSONValue? {
  let urlString = media.url.absoluteString

  // data: URIs can be resolved inline without the resolver
  if urlString.hasPrefix("data:") {
    return mediaPart(forWireType: wireMediaType(media.mimeType), urlString: urlString)
  }

  // https:// URLs pass through if supported
  if urlString.hasPrefix("https://") || urlString.hasPrefix("http://") {
    return mediaPart(forWireType: wireMediaType(media.mimeType), urlString: urlString)
  }

  // Any other reference is resolved through the injected resolver, if present.
  if let mediaResolver, let resolved = try await mediaResolver.resolve(media) {
    switch resolved {
    case let .data(data, mimeType: mt):
      // A text/* document is not image/audio/video media: Chat Completions has
      // no content-part for it, and providers that gate media on images (e.g.
      // DeepSeek) reject a non-image `image_url` part outright. Inline the
      // decoded bytes as a plain text part instead — the model reads the file's
      // contents directly. Binary types still ride as a base64 data URI.
      if isInlineableText(mt) {
        return textPart(named: media.url.lastPathComponent, decoding: data)
      }
      let b64 = data.base64EncodedString()
      let dataURI = "data:\(mt);base64,\(b64)"
      return mediaPart(forWireType: wireMediaType(mt), urlString: dataURI)
    case let .url(resolvedURL, mimeType: mt):
      return mediaPart(forWireType: wireMediaType(mt), urlString: resolvedURL.absoluteString)
    case let .text(text):
      return .object(["type": .string("text"), "text": .string(text)])
    }
  }

  // Unsupported scheme → nil, caller inserts placeholder
  return nil
}

/// Map a MIME type to the Chat Completions wire content-part type.
private func wireMediaType(_ mimeType: String) -> String {
  if mimeType.hasPrefix("video/") { return "video_url" }
  if mimeType.hasPrefix("audio/") { return "audio_url" }
  return "image_url"
}

/// Whether a resolved attachment's MIME type is a UTF-8 text document we inline
/// verbatim as a text content part rather than as image/audio/video media.
/// Covers `text/*` and the common text-shaped `application/*` types.
private func isInlineableText(_ mimeType: String) -> Bool {
  let mt = mimeType.lowercased()
  if mt.hasPrefix("text/") { return true }
  return [
    "application/json",
    "application/xml",
    "application/markdown",
    "application/x-markdown",
    "application/yaml",
    "application/x-yaml",
    "application/javascript",
    "application/x-ndjson",
  ].contains(mt)
}

/// A text content-part carrying an inlined attachment's decoded contents, framed
/// with the filename so the model can attribute it.
private func textPart(named name: String, decoding data: Data) -> JSONValue {
  let text = String(decoding: data, as: UTF8.self)
  let framed = name.isEmpty ? text : "Attached file \(name):\n\(text)"
  return .object([
    "type": .string("text"),
    "text": .string(framed),
  ])
}

/// Build a media content-part JSON object for the given wire type.
private func mediaPart(forWireType wireType: String, urlString: String) -> JSONValue {
  .object([
    "type": .string(wireType),
    wireType: .object(["url": .string(urlString)]),
  ])
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue? {
  guard case let .function(name, description, parameters) = tool else { return nil }
  return .object([
    "type": .string("function"),
    "function": .object([
      "name": .string(name),
      "description": .string(description),
      "parameters": parameters,
    ]),
  ])
}

// MARK: - Helpers

private func formatToolResultContent(_ blocks: [ContentBlock]) -> String {
  blocks.compactMap { block -> String? in
    if case let .text(text) = block { return text.text }
    return nil
  }.joined(separator: "\n")
}
