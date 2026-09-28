import Foundation
import JSONValue
import OrderedCollections

// MARK: - Responses Request Builder

/// Build an OpenAI Responses API request body from domain types.
///
/// Wire format: OpenAI `/v1/responses`, SSE streaming.
func buildResponsesRequest(
  model: String,
  baseURL: URL,
  context: Context,
  options: RequestOptions,
  isCodex: Bool,
  mediaResolver: (any MediaResolver)? = nil,
) async throws -> (url: URL, headers: [String: String], body: OrderedDictionary<String, JSONValue>) {
  let url = baseURL.appendingPathComponent("responses")

  let headers: [String: String] = [
    "content-type": "application/json",
    "accept": "text/event-stream",
  ]

  let input = try await buildInput(context: context, isCodex: isCodex, mediaResolver: mediaResolver)
  var body: OrderedDictionary<String, JSONValue> = [
    "model": .string(model),
    "input": .array(input),
    "stream": .bool(true),
    "store": .bool(false),
  ]

  switch options.reasoning {
  case .none:
    break
  case .automatic:
    body["reasoning"] = .object([
      "effort": .string("medium"),
      "summary": .string("auto"),
    ])
    body["include"] = .array([.string("reasoning.encrypted_content")])
  case .effort(let effort):
    body["reasoning"] = .object([
      "effort": .string(effort),
      "summary": .string("auto"),
    ])
    body["include"] = .array([.string("reasoning.encrypted_content")])
  case .budget(let tokens):
    body["reasoning"] = .object([
      "effort": .string("medium"),
      "summary": .string("auto"),
      "max_tokens": .integer(tokens),
    ])
    body["include"] = .array([.string("reasoning.encrypted_content")])
  }

  if let temperature = options.temperature {
    body["temperature"] = .number(temperature)
  }
  if !isCodex, let maxTokens = options.maxTokens {
    body["max_output_tokens"] = .integer(maxTokens)
  }
  var tools = context.tools ?? []
  if isCodex { tools.append(.hosted(type: "web_search")) }
  if !tools.isEmpty {
    body["tools"] = .array(tools.map(buildTool))
  }

  switch options.toolChoice {
  case .none:
    break
  case .any:
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .string("required")
  case let .tool(name):
    precondition(!(context.tools ?? []).isEmpty, "tool forcing requires tools")
    body["tool_choice"] = .object(["type": .string("function"), "name": .string(name)])
  }

  // Codex: instructions go into body (handled by endpoint's modifyBody)
  if isCodex, let systemPrompt = context.systemPrompt {
    body["instructions"] = .string(systemPrompt)
  }

  return (url, headers, body)
}

// MARK: - Input

private func buildInput(
  context: Context,
  isCodex: Bool,
  mediaResolver: (any MediaResolver)?,
) async throws -> [JSONValue] {
  var input: [JSONValue] = []

  // System prompt
  if !isCodex, let system = context.systemPrompt, !system.isEmpty {
    input.append(.object([
      "role": .string("system"),
      "content": .string(system),
    ]))
  }

  var msgIndex = 0

  for message in context.messages {
    switch message {
    case let .user(m):
      let text = m.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined(separator: "\n")

      var imageBlocks: [JSONValue] = []
      for block in m.content {
        guard case let .media(media) = block else { continue }
        if let imageBlock = try await inputImageBlock(media, mediaResolver: mediaResolver) {
          imageBlocks.append(imageBlock)
        }
      }

      if imageBlocks.isEmpty {
        guard !text[...].trimmedWhitespace.isEmpty else { continue }
        input.append(.object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("input_text"),
              "text": .string(text),
            ]),
          ]),
        ]))
      } else {
        var contentBlocks: [JSONValue] = []
        if !text[...].trimmedWhitespace.isEmpty {
          contentBlocks.append(.object([
            "type": .string("input_text"),
            "text": .string(text),
          ]))
        }
        contentBlocks.append(contentsOf: imageBlocks)
        input.append(.object([
          "role": .string("user"),
          "content": .array(contentBlocks),
        ]))
      }

    case let .assistant(m):
      for block in m.content {
        switch block {
        case let .text(part):
          let id = "msg_\(msgIndex)"
          input.append(.object([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([
              .object([
                "type": .string("output_text"),
                "text": .string(part.text),
                "annotations": .array([]),
              ]),
            ]),
            "status": .string("completed"),
            "id": .string(id),
          ]))
          msgIndex += 1

          if let phase = m.phase {
            if case var .object(lastObj) = input[input.count - 1] {
              lastObj["phase"] = .string(phase.rawValue)
              input[input.count - 1] = .object(lastObj)
            }
          }

        case let .toolCall(call):
          // `call.id` is already a wire-safe `call_id` (normalized upstream in
          // `buildRequest`). The output-item `id` is intentionally omitted — it
          // is not needed to replay a function call.
          input.append(.object([
            "type": .string("function_call"),
            "call_id": .string(call.id),
            "name": .string(call.name),
            "arguments": .string(call.arguments.text),
          ]))

        case let .reasoning(reasoning):
          switch reasoning {
          case .unencrypted:
            // Responses rejects `reasoning.content` on input and drops `summary`
            // before the model sees it; there is no channel to replay into.
            continue

          case let .encrypted(enc):
            guard !enc.opaque.isEmpty else { continue }

            var obj: OrderedDictionary<String, JSONValue> = ["type": .string("reasoning")]
            // A fabricated `rs_` id is looked up server-side and 404s the request.
            if let id = enc.id {
              obj["id"] = .string(id)
            }
            obj["summary"] = .array([])
            obj["encrypted_content"] = .string(enc.opaque)
            if let summary = enc.summary {
              obj["summary"] = .array([
                .object([
                  "type": .string("summary_text"),
                  "text": .string(summary),
                ]),
              ])
            }
            input.append(.object(obj))
          }

        case let .hostedTool(item):
          input.append(item.payload)

        case .media:
          // Media in assistant messages not supported in Responses.
          break
        }
      }

    case let .toolResult(m):
      let outputText = m.content.compactMap { block -> String? in
        if case let .text(t) = block { return t.text }
        return nil
      }.joined(separator: "\n")

      input.append(.object([
        "type": .string("function_call_output"),
        "call_id": .string(m.toolCallId),
        "output": .string(outputText.isEmpty ? "(no output)" : outputText),
      ]))
    }
  }

  return input
}

private func inputImageBlock(
  _ media: MediaContent,
  mediaResolver: (any MediaResolver)?,
) async throws -> JSONValue? {
  let urlString = media.url.absoluteString
  if isResponsesImageURL(urlString) { return inputImage(urlString) }

  // Any other reference is resolved through the injected resolver, if present.
  if let mediaResolver, let resolved = try await mediaResolver.resolve(media) {
    switch resolved {
    case let .data(data, mimeType):
      return inputImage("data:\(mimeType);base64,\(data.base64EncodedString())")
    case let .url(url, _):
      let resolvedString = url.absoluteString
      return isResponsesImageURL(resolvedString) ? inputImage(resolvedString) : nil
    case let .text(text):
      return .object(["type": .string("input_text"), "text": .string(text)])
    }
  }

  return nil
}

// "original" keeps the image's own size; "auto" may shrink it to a preset.
private func inputImage(_ urlString: String) -> JSONValue {
  .object([
    "type": .string("input_image"),
    "detail": .string("original"),
    "image_url": .string(urlString),
  ])
}

private func isResponsesImageURL(_ urlString: String) -> Bool {
  urlString.hasPrefix("data:") || urlString.hasPrefix("https://") || urlString.hasPrefix("http://")
}

// MARK: - Tools

private func buildTool(_ tool: Tool) -> JSONValue {
  switch tool {
  case let .function(name, description, parameters):
    .object([
      "type": .string("function"),
      "name": .string(name),
      "description": .string(description),
      "parameters": parameters,
      "strict": .bool(false),
    ])
  case let .hosted(type):
    .object(["type": .string(type)])
  }
}
