import Foundation
import JSONValue
import OrderedCollections

// MARK: - Anthropic Request Builder

/// Build an Anthropic Messages API request body from domain types.
///
/// Wire format: Anthropic Messages API, SSE content-block streaming.
func buildAnthropicRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
  acceptsUnsignedThinking: Bool = true,
  mediaResolver: (any MediaResolver)? = nil,
) async throws -> (url: URL, headers: [String: String], body: OrderedDictionary<String, JSONValue>) {
  let url = baseURL.appendingPathComponent("messages")

  let headers: [String: String] = [
    "content-type": "application/json",
    "accept": "text/event-stream",
    "anthropic-version": "2023-06-01",
  ]

  var body: OrderedDictionary<String, JSONValue> = [
    "model": .string(model),
    "messages": .array(try await buildMessages(
      context: context,
      acceptsUnsignedThinking: acceptsUnsignedThinking,
      mediaResolver: mediaResolver,
    )),
    "stream": .bool(true),
    "max_tokens": .integer(options.maxTokens ?? 16384),
  ]

  if let temperature = options.temperature {
    body["temperature"] = .number(temperature)
  }

  // System prompt
  if let system = context.systemPrompt, !system.isEmpty {
    body["system"] = .string(system)
  }

  // Tools
  let tools = (context.tools ?? []).compactMap(buildTool)
  if !tools.isEmpty {
    body["tools"] = .array(tools)
  }

  switch options.toolChoice {
  case .none:
    break
  case .any:
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .object(["type": .string("any")])
  case let .tool(name):
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .object(["type": .string("tool"), "name": .string(name)])
  }

  return (url, headers, body)
}

// MARK: - Messages

private func buildMessages(
  context: Context,
  acceptsUnsignedThinking: Bool,
  mediaResolver: (any MediaResolver)?,
) async throws -> [JSONValue] {
  var messages: [JSONValue] = []
  // Local working copy: the parallel-tool-call splice below re-inserts buffered
  // interleaved entries after the paired tool_result message.
  var queue = context.messages
  var i = 0

  while i < queue.count {
    let message = queue[i]

    switch message {
    case let .user(m):
      let blocks = try await buildUserContentBlocks(m.content, mediaResolver: mediaResolver)
      if !blocks.isEmpty {
        messages.append(.object([
          "role": .string("user"),
          "content": .array(blocks),
        ]))
      }
      i += 1

    case let .assistant(m):
      let blocks = buildAssistantContentBlocks(m.content, acceptsUnsignedThinking: acceptsUnsignedThinking)
      if !blocks.isEmpty {
        messages.append(.object([
          "role": .string("assistant"),
          "content": .array(blocks),
        ]))
      }
      i += 1

      // Anthropic block-pairing invariant: every `tool_use` block in this
      // assistant turn must be answered by a `tool_result` block in the
      // immediately-following user message. The transcript may interleave
      // non-result entries (e.g. a rendered `.effect` user message) between
      // sibling tool results of a parallel tool-call turn. Gather ALL tool
      // results belonging to this turn's tool_use ids — in any interleaving
      // order — into that one user message, then re-emit the interleaved
      // entries afterward so no `tool_use` is ever orphaned (DeepSeek's
      // Anthropic-dialect endpoint rejects the whole request otherwise).
      let toolUseIDs = assistantToolUseIDs(m.content)
      if !toolUseIDs.isEmpty {
        var pending = toolUseIDs
        var toolResults: [JSONValue] = []
        var deferred: [Message] = []
        while i < queue.count, !pending.isEmpty {
          if case let .toolResult(result) = queue[i], pending.contains(result.toolCallId) {
            toolResults.append(buildToolResultBlock(result))
            pending.remove(result.toolCallId)
          } else {
            deferred.append(queue[i])
          }
          i += 1
        }
        if !toolResults.isEmpty {
          messages.append(.object([
            "role": .string("user"),
            "content": .array(toolResults),
          ]))
        }
        // Splice the buffered interleaved entries back into the stream so the
        // outer loop processes them after the paired tool_result message.
        queue.replaceSubrange(i ..< i, with: deferred)
      }

    case let .toolResult(m):
      // Tool results that did not pair with a preceding assistant turn (e.g. a
      // history that begins mid-stream). Group consecutive ones into one user
      // message, matching Anthropic's single tool_result message convention.
      var toolResults: [JSONValue] = [buildToolResultBlock(m)]
      i += 1
      while i < queue.count {
        guard case let .toolResult(next) = queue[i] else { break }
        toolResults.append(buildToolResultBlock(next))
        i += 1
      }
      messages.append(.object([
        "role": .string("user"),
        "content": .array(toolResults),
      ]))
    }
  }

  return messages
}

/// The `tool_use` ids carried by an assistant turn, in order.
private func assistantToolUseIDs(_ blocks: [ContentBlock]) -> Set<String> {
  var ids: Set<String> = []
  for block in blocks {
    if case let .toolCall(call) = block { ids.insert(call.id) }
  }
  return ids
}

private func buildToolResultBlock(_ m: ToolResultMessage) -> JSONValue {
  let text = m.content.compactMap { block -> String? in
    if case let .text(t) = block { return t.text }
    return nil
  }.joined(separator: "\n")

  return .object([
    "type": .string("tool_result"),
    "tool_use_id": .string(m.toolCallId),
    "content": .string(text.isEmpty ? "(no output)" : text),
    "is_error": .bool(m.isError),
  ])
}

// MARK: - Content Blocks

private func buildUserContentBlocks(
  _ blocks: [ContentBlock],
  mediaResolver: (any MediaResolver)?,
) async throws -> [JSONValue] {
  var parts: [JSONValue] = []

  for block in blocks {
    switch block {
    case let .text(text):
      if !text.text[...].trimmedWhitespace.isEmpty {
        parts.append(.object([
          "type": .string("text"),
          "text": .string(text.text),
        ]))
      }

    case let .media(media):
      if let part = try await buildAnthropicMediaBlock(media, mediaResolver: mediaResolver) {
        parts.append(part)
      }

    case .reasoning, .toolCall, .hostedTool:
      break
    }
  }

  return parts
}

private func buildAnthropicMediaBlock(
  _ media: MediaContent,
  mediaResolver: (any MediaResolver)?,
) async throws -> JSONValue? {
  let urlString = media.url.absoluteString
  if urlString.hasPrefix("data:"), let base64 = extractBase64(from: urlString) {
    return base64ImageBlock(base64: base64, mimeType: media.mimeType)
  }

  if urlString.hasPrefix("https://") || urlString.hasPrefix("http://") {
    return .object([
      "type": .string("image"),
      "source": .object([
        "type": .string("url"),
        "url": .string(urlString),
      ]),
    ])
  }

  // Any other reference is resolved through the injected resolver, if present.
  if let mediaResolver, let resolved = try await mediaResolver.resolve(media) {
    switch resolved {
    case let .data(data, mimeType):
      // A text/* document is not an image. Anthropic's `image` block (and the
      // DeepSeek Anthropic-compatible endpoint, which gates `source.media_type`
      // on image types) rejects a non-image media_type outright. Inline the
      // decoded bytes as a plain text block instead — the model reads the file's
      // contents directly. Binary types still ride as a base64 image block.
      if isInlineableText(mimeType) {
        return anthropicTextBlock(named: media.url.lastPathComponent, decoding: data)
      }
      return base64ImageBlock(base64: data.base64EncodedString(), mimeType: mimeType)
    case let .url(url, _):
      let resolvedString = url.absoluteString
      guard resolvedString.hasPrefix("https://") || resolvedString.hasPrefix("http://") else { return nil }
      return .object([
        "type": .string("image"),
        "source": .object([
          "type": .string("url"),
          "url": .string(resolvedString),
        ]),
      ])
    case let .text(text):
      return .object(["type": .string("text"), "text": .string(text)])
    }
  }

  return nil
}

/// Whether a resolved attachment's MIME type is a UTF-8 text document we inline
/// verbatim as a text block rather than as an image. Covers `text/*` and the
/// common text-shaped `application/*` types.
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

/// A text block carrying an inlined attachment's decoded contents, framed with
/// the filename so the model can attribute it.
private func anthropicTextBlock(named name: String, decoding data: Data) -> JSONValue {
  let text = String(decoding: data, as: UTF8.self)
  let framed = name.isEmpty ? text : "Attached file \(name):\n\(text)"
  return .object([
    "type": .string("text"),
    "text": .string(framed),
  ])
}

private func base64ImageBlock(base64: String, mimeType: String) -> JSONValue {
  .object([
    "type": .string("image"),
    "source": .object([
      "type": .string("base64"),
      "media_type": .string(mimeType),
      "data": .string(base64),
    ]),
  ])
}

private func buildAssistantContentBlocks(
  _ blocks: [ContentBlock],
  acceptsUnsignedThinking: Bool,
) -> [JSONValue] {
  var parts: [JSONValue] = []

  for block in blocks {
    switch block {
    case let .text(text):
      if !text.text[...].trimmedWhitespace.isEmpty {
        parts.append(.object([
          "type": .string("text"),
          "text": .string(text.text),
        ]))
      }

    case let .reasoning(reasoning):
      if let block = buildAnthropicReasoningBlock(reasoning, acceptsUnsignedThinking: acceptsUnsignedThinking) {
        parts.append(block)
      }

    case let .toolCall(call):
      parts.append(.object([
        "type": .string("tool_use"),
        "id": .string(call.id),
        "name": .string(call.name),
        "input": call.arguments.json,
      ]))

    case .hostedTool, .media:
      break
    }
  }

  return parts
}

// MARK: - Reasoning

private func buildAnthropicReasoningBlock(
  _ reasoning: ReasoningContent,
  acceptsUnsignedThinking: Bool,
) -> JSONValue? {
  switch reasoning {
  case let .unencrypted(text):
    guard !text[...].trimmedWhitespace.isEmpty else { return nil }
    guard acceptsUnsignedThinking else {
      return .object([
        "type": .string("text"),
        "text": .string(text),
      ])
    }
    return .object([
      "type": .string("thinking"),
      "thinking": .string(text),
    ])

  case let .encrypted(enc):
    // Redacted thinking (no summary, opaque only)
    if enc.redacted {
      return .object([
        "type": .string("redacted_thinking"),
        "data": .string(enc.opaque),
      ])
    }

    // Regular thinking with signature
    let text = enc.summary ?? ""
    let hasText = !text[...].trimmedWhitespace.isEmpty
    let hasSignature = !enc.opaque.isEmpty
    guard hasText || hasSignature else { return nil }

    var block: OrderedDictionary<String, JSONValue> = [
      "type": .string("thinking"),
      "thinking": .string(text),
    ]
    if hasSignature {
      block["signature"] = .string(enc.opaque)
    }
    return .object(block)
  }
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue? {
  guard case let .function(name, description, parameters) = tool else { return nil }
  return .object([
    "name": .string(name),
    "description": .string(description),
    "input_schema": parameters,
  ])
}

// MARK: - Helpers

private func extractBase64(from dataURI: String) -> String? {
  // data:image/png;base64,XXXX
  guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
  let index = dataURI.index(after: commaIndex)
  return String(dataURI[index...])
}
