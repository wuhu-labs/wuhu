import Foundation
import JSONValue
import OrderedCollections

// MARK: - Gemini Request Builder

/// Build a Google Gemini API request body from domain types.
///
/// Wire format: Google Gemini API (`@google/genai` protocol).
func buildGeminiRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
  mediaResolver: (any MediaResolver)? = nil,
) async throws -> (url: URL, headers: [String: String], body: OrderedDictionary<String, JSONValue>) {
  let url = baseURL
    .appendingPathComponent("models")
    .appendingPathComponent("\(model):streamGenerateContent")
    .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])

  let headers: [String: String] = [
    "content-type": "application/json",
  ]

  var body: OrderedDictionary<String, JSONValue> = [:]

  // System instruction
  if let system = context.systemPrompt, !system.isEmpty {
    body["systemInstruction"] = .object([
      "parts": .array([
        .object(["text": .string(system)]),
      ]),
    ])
  }

  // Contents
  body["contents"] = .array(try await buildContents(context: context, mediaResolver: mediaResolver))

  // Generation config
  var generationConfig: OrderedDictionary<String, JSONValue> = [:]
  if let temperature = options.temperature {
    generationConfig["temperature"] = .number(temperature)
  }
  if let maxTokens = options.maxTokens {
    generationConfig["maxOutputTokens"] = .integer(maxTokens)
  }
  if !generationConfig.isEmpty {
    body["generationConfig"] = .object(generationConfig)
  }

  // Tools
  let tools = (context.tools ?? []).compactMap(buildTool)
  if !tools.isEmpty {
    body["tools"] = .array([
      .object([
        "functionDeclarations": .array(tools),
      ]),
    ])
  }

  switch options.toolChoice {
  case .none:
    break
  case .any:
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["toolConfig"] = .object([
      "functionCallingConfig": .object(["mode": .string("ANY")]),
    ])
  case let .tool(name):
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["toolConfig"] = .object([
      "functionCallingConfig": .object([
        "mode": .string("ANY"),
        "allowedFunctionNames": .array([.string(name)]),
      ]),
    ])
  }

  return (url, headers, body)
}

// MARK: - Contents

private func buildContents(context: Context, mediaResolver: (any MediaResolver)?) async throws -> [JSONValue] {
  var contents: [JSONValue] = []
  var i = 0

  while i < context.messages.count {
    let message = context.messages[i]

    switch message {
    case let .user(m):
      var parts: [JSONValue] = []

      for block in m.content {
        switch block {
        case let .text(text):
          if !text.text.isEmpty {
            parts.append(.object(["text": .string(text.text)]))
          }

        case let .media(media):
          if let part = try await buildGeminiMediaPart(media, mediaResolver: mediaResolver) {
            parts.append(part)
          }

        case .reasoning, .toolCall, .hostedTool:
          break
        }
      }

      if !parts.isEmpty {
        contents.append(.object([
          "role": .string("user"),
          "parts": .array(parts),
        ]))
      }
      i += 1

    case let .assistant(m):
      var parts: [JSONValue] = []

      for (j, block) in m.content.enumerated() {
        // Gemini thoughtSignature fusion: if an encrypted reasoning block
        // sits immediately before a text/toolCall block,
        // attach thoughtSignature to that part.
        let nextBlock = j + 1 < m.content.count ? m.content[j + 1] : nil

        switch block {
        case let .text(text):
          var part: OrderedDictionary<String, JSONValue> = ["text": .string(text.text)]

          // Check if previous block was encrypted reasoning for fusion
          if j > 0, case let .reasoning(reasoning) = m.content[j - 1],
             case let .encrypted(enc) = reasoning,
             !enc.opaque.isEmpty
          {
            // Attach thoughtSignature
            part["thoughtSignature"] = .string(enc.opaque)
          }

          parts.append(.object(part))

        case let .reasoning(reasoning):
          switch reasoning {
          case .unencrypted:
            // Unencrypted reasoning → standalone thought part
            var thoughtPart: OrderedDictionary<String, JSONValue> = ["thought": .bool(true)]
            if case let .unencrypted(text) = reasoning {
              thoughtPart["text"] = .string(text)
            }
            parts.append(.object(thoughtPart))

          case let .encrypted(enc):
            // Check if this should be fused (followed by text/toolCall)
            if let next = nextBlock,
               case .text = next
            {
              continue
            }
            if let next = nextBlock,
               case .toolCall = next
            {
              continue
            }

            // Standalone thought part
            var thoughtPart: OrderedDictionary<String, JSONValue> = [
              "thought": .bool(true),
            ]
            if let text = enc.summary {
              thoughtPart["text"] = .string(text)
            }
            if !enc.opaque.isEmpty {
              thoughtPart["thoughtSignature"] = .string(enc.opaque)
            }
            parts.append(.object(thoughtPart))
          }

        case let .toolCall(call):
          var funcPart: OrderedDictionary<String, JSONValue> = [
            "functionCall": .object([
              "name": .string(call.name),
              "args": call.arguments.json,
            ]),
          ]

          // Check if previous block was encrypted reasoning for fusion
          if j > 0, case let .reasoning(reasoning) = m.content[j - 1],
             case let .encrypted(enc) = reasoning,
             !enc.opaque.isEmpty
          {
            funcPart["thoughtSignature"] = .string(enc.opaque)
          }

          parts.append(.object(funcPart))

        case .hostedTool, .media:
          break
        }
      }

      if !parts.isEmpty {
        contents.append(.object([
          "role": .string("model"),
          "parts": .array(parts),
        ]))
      }
      i += 1

    case .toolResult:
      // Group consecutive tool results
      var toolResultParts: [JSONValue] = []
      while i < context.messages.count {
        guard case let .toolResult(m) = context.messages[i] else { break }

        // Derive tool name from the matching ToolCall in preceding messages.
        let toolName = deriveToolName(for: m.toolCallId, from: context.messages, before: i)

        var response: OrderedDictionary<String, JSONValue> = [
          "name": .string(toolName),
        ]

        let text = m.content.compactMap { block -> String? in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined(separator: "\n")

        // Tool-result text may contain a structured JSON object. Scalars keep
        // the stable Gemini fallback shape instead of becoming raw responses.
        if let parsed = JSONValue.parseObject(text) {
          response["response"] = parsed
        } else {
          response["response"] = .object(["result": .string(text)])
        }

        toolResultParts.append(.object([
          "functionResponse": .object(response),
        ]))
        i += 1
      }

      if !toolResultParts.isEmpty {
        contents.append(.object([
          "role": .string("user"),
          "parts": .array(toolResultParts),
        ]))
      }
    }
  }

  return contents
}

private func buildGeminiMediaPart(
  _ media: MediaContent,
  mediaResolver: (any MediaResolver)?,
) async throws -> JSONValue? {
  let urlString = media.url.absoluteString
  if urlString.hasPrefix("data:"), let base64 = extractBase64(from: urlString) {
    return inlineDataPart(base64: base64, mimeType: media.mimeType)
  }

  if isGeminiFileURL(urlString) {
    return fileDataPart(urlString: urlString, mimeType: media.mimeType)
  }

  // Any other reference is resolved through the injected resolver, if present.
  if let mediaResolver, let resolved = try await mediaResolver.resolve(media) {
    switch resolved {
    case let .data(data, mimeType):
      return inlineDataPart(base64: data.base64EncodedString(), mimeType: mimeType)
    case let .url(url, mimeType):
      let resolvedString = url.absoluteString
      return isGeminiFileURL(resolvedString) ? fileDataPart(urlString: resolvedString, mimeType: mimeType) : nil
    case let .text(text):
      return .object(["text": .string(text)])
    }
  }

  return nil
}

private func inlineDataPart(base64: String, mimeType: String) -> JSONValue {
  .object([
    "inlineData": .object([
      "mimeType": .string(mimeType),
      "data": .string(base64),
    ]),
  ])
}

private func fileDataPart(urlString: String, mimeType: String) -> JSONValue {
  .object([
    "fileData": .object([
      "mimeType": .string(mimeType),
      "fileUri": .string(urlString),
    ]),
  ])
}

private func isGeminiFileURL(_ urlString: String) -> Bool {
  urlString.hasPrefix("https://") || urlString.hasPrefix("http://") || urlString.hasPrefix("gs://")
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue? {
  guard case let .function(name, description, parameters) = tool else { return nil }
  return .object([
    "name": .string(name),
    "description": .string(description),
    "parameters": parameters,
  ])
}

// MARK: - Helpers

/// Derive a tool name by scanning preceding messages for the matching ToolCall.
private func deriveToolName(for toolCallId: String, from messages: [Message], before index: Int) -> String {
  // Scan backward through messages to find the matching ToolCall.
  for msg in messages[..<index].reversed() {
    guard case let .assistant(m) = msg else { continue }
    for block in m.content {
      guard case let .toolCall(tc) = block else { continue }
      // IDs are normalized identically on both the tool call and its result
      // (see `wireToolCallID`), so a direct match is sufficient.
      if tc.id == toolCallId {
        return tc.name
      }
    }
  }
  return "tool"
}

private func extractBase64(from dataURI: String) -> String? {
  guard let commaIndex = dataURI.firstIndex(of: ",") else { return nil }
  let index = dataURI.index(after: commaIndex)
  return String(dataURI[index...])
}
