import Foundation
import JSONValue
import OrderedCollections

// MARK: - Chat Completions Stream Parser

/// Parse Chat Completions SSE stream into InferenceEvent domain events.
func parseChatCompletionsStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<InferenceEvent, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      var content: [ContentBlock] = []
      let phase: AssistantMessagePhase? = nil
      var stopReason: StopReason = .stop
      var usage: Usage?

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var currentToolCallIndex: Int?
      var currentToolCallBuffer: (id: String, name: String, arguments: String)?
      var currentReasoningIndex: Int?
      var sawDoneMarker = false

      func closeText() {
        guard let idx = currentTextIndex, idx < content.count,
              case let .text(part) = content[idx]
        else {
          currentTextIndex = nil
          return
        }
        continuation.yield(.textEnd(contentIndex: idx, text: part.text, partial: partial()))
        currentTextIndex = nil
      }

      func closeReasoning() {
        guard let idx = currentReasoningIndex, idx < content.count,
              case let .reasoning(reasoning) = content[idx]
        else {
          currentReasoningIndex = nil
          return
        }
        continuation.yield(.reasoningEnd(
          contentIndex: idx,
          text: reasoning.text ?? "",
          partial: partial(),
        ))
        currentReasoningIndex = nil
      }

      do {
        for try await sseEvent in sse {
          if sseEvent.data[...].trimmedWhitespace == "[DONE]" {
            sawDoneMarker = true
            break
          }

          guard let dict = parseChatJSON(sseEvent.data) else { continue }

          // DashScope delivers usage in a trailing chunk whose choices array
          // is empty, so this must run before the choices guard.
          if let usageDict = dict["usage"]?.object {
            usage = parseUsage(from: usageDict)
          }

          guard let choices = dict["choices"]?.array?.compactMap(\.object),
                let choice = choices.first
          else { continue }

          let finishReason = choice["finish_reason"]?.stringValue

          if let delta = choice["delta"]?.object {
            // Text delta
            if let text = delta["content"]?.stringValue, !text.isEmpty {
              if let idx = currentTextIndex, idx < content.count,
                 case var .text(part) = content[idx]
              {
                part.text += text
                content[idx] = .text(part)
              } else {
                closeReasoning()
                content.append(.text(TextContent(text: text)))
                currentTextIndex = content.count - 1
                currentToolCallIndex = nil
                continuation.yield(.textStart(
                  contentIndex: currentTextIndex!,
                  partial: partial(),
                ))
              }
              continuation.yield(.textDelta(
                contentIndex: currentTextIndex!,
                delta: text,
                partial: partial(),
              ))
            }

            // Reasoning delta
            if let reasoningText = delta["reasoning_content"]?.stringValue, !reasoningText.isEmpty {
              if let idx = currentReasoningIndex, idx < content.count,
                 case let .reasoning(reasoningContent) = content[idx],
                 case let .unencrypted(existing) = reasoningContent
              {
                content[idx] = .reasoning(.unencrypted(existing + reasoningText))
              } else {
                closeText()
                content.append(.reasoning(.unencrypted(reasoningText)))
                currentReasoningIndex = content.count - 1
                currentToolCallIndex = nil
                continuation.yield(.reasoningStart(
                  contentIndex: currentReasoningIndex!,
                  partial: partial(),
                ))
              }
              continuation.yield(.reasoningDelta(
                contentIndex: currentReasoningIndex!,
                delta: reasoningText,
                partial: partial(),
              ))
            }

            // Reasoning details (MiniMax)
            if let reasoningDetails = delta["reasoning_details"]?.array?.compactMap(\.object) {
              for detail in reasoningDetails {
                if let text = detail["text"]?.stringValue {
                  let signature = detail["signature"]?.stringValue
                  if let idx = currentReasoningIndex, idx < content.count,
                     case let .reasoning(reasoningContent) = content[idx],
                     case var .encrypted(enc) = reasoningContent
                  {
                    enc.summary = (enc.summary ?? "") + text
                    if let sig = signature { enc.opaque = sig }
                    content[idx] = .reasoning(.encrypted(enc))
                  } else {
                    closeText()
                    content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                      providerID: "minimax",
                      model: model,
                      summary: text,
                      opaque: signature ?? "",
                    ))))
                    currentReasoningIndex = content.count - 1
                    currentToolCallIndex = nil
                    continuation.yield(.reasoningStart(
                      contentIndex: currentReasoningIndex!,
                      partial: partial(),
                    ))
                  }
                  continuation.yield(.reasoningDelta(
                    contentIndex: currentReasoningIndex!,
                    delta: text,
                    partial: partial(),
                  ))
                }
              }
            }

            // Tool call delta
            if let toolCalls = delta["tool_calls"]?.array?.compactMap(\.object) {
              for tc in toolCalls {
                let id = tc["id"]?.stringValue
                let function = tc["function"]?.object
                let name = function?["name"]?.stringValue
                let arguments = function?["arguments"]?.stringValue

                // Use index to track tool calls
                if let idx = id ?? name {
                  if currentToolCallBuffer == nil || currentToolCallBuffer?.id != idx {
                    // New tool call
                    let callID = id ?? UUID().uuidString
                    let callName = name ?? ""
                    currentToolCallBuffer = (callID, callName, arguments ?? "")
                    closeText()
                    closeReasoning()
                    content.append(.toolCall(ToolCall(
                      id: callID,
                      name: callName,
                      arguments: .object([:]),
                    )))
                    currentToolCallIndex = content.count - 1
                    continuation.yield(.toolCallStart(
                      contentIndex: currentToolCallIndex!,
                      partial: partial(),
                    ))
                  } else if let args = arguments {
                    currentToolCallBuffer?.arguments += args
                    continuation.yield(.toolCallDelta(
                      contentIndex: currentToolCallIndex!,
                      delta: args,
                      partial: partial(),
                    ))
                  }
                }
              }
            }
          }

          // Handle finish
          if let reason = finishReason {
            // Finalize tool calls
            if let idx = currentToolCallIndex,
               let buffer = currentToolCallBuffer,
               idx < content.count,
               case .toolCall = content[idx]
            {
              let parsed = ToolArguments(verbatim: buffer.arguments) ?? .object([:])
              content[idx] = .toolCall(ToolCall(
                id: buffer.id,
                name: buffer.name,
                arguments: parsed,
              ))
              continuation.yield(.toolCallEnd(
                contentIndex: idx,
                toolCall: ToolCall(id: buffer.id, name: buffer.name, arguments: parsed),
                partial: partial(),
              ))
              currentToolCallIndex = nil
              currentToolCallBuffer = nil
            }

            closeText()
            closeReasoning()

            stopReason = mapChatCompletionsFinishReason(reason)
          }
        }

        guard sawDoneMarker else {
          throw ProviderStreamError.invalidStream(
            "Chat Completions stream ended before [DONE]",
          )
        }

        closeText()
        closeReasoning()

        if stopReason == .stop,
           content.contains(where: { if case .toolCall = $0 { true } else { false } })
        {
          stopReason = .stop
        }

        continuation.yield(.done(partial(), AssistantMessageMetadata(stopReason: stopReason, usage: usage)))
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

// MARK: - Helpers

private func parseChatJSON(_ text: String) -> OrderedDictionary<String, JSONValue>? {
  JSONValue.parse(text)?.object
}

private func parseUsage(from dict: OrderedDictionary<String, JSONValue>) -> Usage {
  let input = dict["input_tokens"]?.intValue ?? dict["prompt_tokens"]?.intValue ?? 0
  let outputTokens = dict["output_tokens"]?.intValue ?? dict["completion_tokens"]?.intValue ?? 0
  let total = dict["total_tokens"]?.intValue ?? (input + outputTokens)
  let cacheRead = dict["cache_read_input_tokens"]?.intValue
    ?? dict["prompt_cache_hit_tokens"]?.intValue
    ?? dict["prompt_tokens_details"]?.object?["cached_tokens"]?.intValue
    ?? 0
  let cacheWrite = dict["cache_creation_input_tokens"]?.intValue ?? 0
  let reasoning = dict["reasoning_tokens"]?.intValue
    ?? dict["completion_tokens_details"]?.object?["reasoning_tokens"]?.intValue
    ?? 0

  return Usage(
    inputTokens: input,
    outputTokens: outputTokens,
    cacheReadTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    reasoningTokens: reasoning,
    totalTokens: total,
  )
}

private func mapChatCompletionsFinishReason(_ reason: String) -> StopReason {
  switch reason {
  case "stop", "tool_calls", "function_call": return .stop
  case "length": return .maxTokens
  case "content_filter": return .refusal
  default: return .stop
  }
}

private extension ReasoningContent {
  var text: String? {
    switch self {
    case let .unencrypted(text): return text
    case let .encrypted(enc): return enc.summary
    }
  }
}
