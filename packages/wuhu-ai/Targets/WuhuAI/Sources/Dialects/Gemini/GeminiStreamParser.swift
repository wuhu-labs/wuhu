import Foundation
import JSONValue
import OrderedCollections

// MARK: - Gemini Stream Parser

/// Parse Google Gemini SSE stream into InferenceEvent domain events.
///
/// Gemini's streaming format uses JSON arrays in SSE data.
/// Each SSE event's data is a JSON array like `[{...}]`.
func parseGeminiStream(
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
      var currentReasoningIndex: Int?
      var sawFinishReason = false

      do {
        for try await sseEvent in sse {
          guard let dicts = parseGeminiResponse(sseEvent.data) else { continue }

          for dict in dicts {
            if let usageMetadata = dict["usageMetadata"]?.object {
              usage = parseGeminiUsage(from: usageMetadata)
            }

            guard let candidates = dict["candidates"]?.array?.compactMap(\.object),
                  let candidate = candidates.first
            else { continue }

            if let finishReason = candidate["finishReason"]?.stringValue {
              sawFinishReason = true
              stopReason = mapGeminiFinishReason(finishReason)
              applyGeminiFinishReason(
                &content,
                &currentTextIndex,
                &currentReasoningIndex,
                &currentToolCallIndex,
                continuation,
              )
            }

            guard let candidateContent = candidate["content"]?.object,
                  let parts = candidateContent["parts"]?.array?.compactMap(\.object)
            else { continue }

            for part in parts {
              if part["thought"]?.boolValue == true {
                let thoughtText = part["text"]?.stringValue
                let thoughtSignature = part["thoughtSignature"]?.stringValue

                if let sig = thoughtSignature {
                  content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                    providerID: providerID,
                    model: model,
                    summary: thoughtText,
                    opaque: sig,
                  ))))
                  currentReasoningIndex = content.count - 1
                  currentTextIndex = nil
                  currentToolCallIndex = nil
                  continuation.yield(.reasoningStart(
                    contentIndex: currentReasoningIndex!,
                    partial: partial(),
                  ))

                  if let text = thoughtText {
                    continuation.yield(.reasoningDelta(
                      contentIndex: currentReasoningIndex!,
                      delta: text,
                      partial: partial(),
                    ))
                    continuation.yield(.reasoningEnd(
                      contentIndex: currentReasoningIndex!,
                      text: text,
                      partial: partial(),
                    ))
                    currentReasoningIndex = nil
                  }
                } else if let text = thoughtText {
                  content.append(.reasoning(.unencrypted(text)))
                  currentReasoningIndex = content.count - 1
                  currentTextIndex = nil
                  currentToolCallIndex = nil
                  continuation.yield(.reasoningStart(
                    contentIndex: currentReasoningIndex!,
                    partial: partial(),
                  ))
                  continuation.yield(.reasoningDelta(
                    contentIndex: currentReasoningIndex!,
                    delta: text,
                    partial: partial(),
                  ))
                  continuation.yield(.reasoningEnd(
                    contentIndex: currentReasoningIndex!,
                    text: text,
                    partial: partial(),
                  ))
                  currentReasoningIndex = nil
                }

              } else if let text = part["text"]?.stringValue {
                let thoughtSignature = part["thoughtSignature"]?.stringValue

                if let sig = thoughtSignature {
                  content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                    providerID: providerID,
                    model: model,
                    summary: nil,
                    opaque: sig,
                  ))))
                  let reasonIdx = content.count - 1
                  currentReasoningIndex = reasonIdx
                  continuation.yield(.reasoningStart(
                    contentIndex: reasonIdx,
                    partial: partial(),
                  ))
                }

                if let idx = currentTextIndex, idx < content.count,
                   case var .text(existing) = content[idx]
                {
                  existing.text += text
                  content[idx] = .text(existing)
                } else {
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

              } else if let functionCall = part["functionCall"]?.object {
                let name = functionCall["name"]?.stringValue ?? "tool"
                let argsJSON = functionCall["args"]?.object.map(ToolArguments.object) ?? .object([:])

                let fcID = functionCall["id"]?.stringValue ?? UUID().uuidString
                content.append(.toolCall(ToolCall(
                  id: fcID,
                  name: name,
                  arguments: argsJSON,
                )))
                currentToolCallIndex = content.count - 1
                currentTextIndex = nil
                currentReasoningIndex = nil

                if let sig = part["thoughtSignature"]?.stringValue {
                  let toolCallBlock = content.removeLast()
                  content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                    providerID: providerID,
                    model: model,
                    summary: nil,
                    opaque: sig,
                  ))))
                  continuation.yield(.reasoningStart(
                    contentIndex: content.count - 1,
                    partial: partial(),
                  ))
                  content.append(toolCallBlock)
                  currentToolCallIndex = content.count - 1
                }

                if let idx = currentToolCallIndex, idx < content.count,
                   case let .toolCall(tc) = content[idx]
                {
                  continuation.yield(.toolCallStart(
                    contentIndex: idx,
                    partial: partial(),
                  ))
                  continuation.yield(.toolCallEnd(
                    contentIndex: idx,
                    toolCall: tc,
                    partial: partial(),
                  ))
                }
              }
            }
          }
        }

        guard sawFinishReason else {
          throw ProviderStreamError.invalidStream(
            "Gemini stream ended before finishReason",
          )
        }

        if let idx = currentTextIndex, idx < content.count,
           case let .text(part) = content[idx]
        {
          continuation.yield(.textEnd(
            contentIndex: idx,
            text: part.text,
            partial: partial(),
          ))
        }

        if let idx = currentReasoningIndex, idx < content.count,
           case let .reasoning(reasoningContent) = content[idx]
        {
          continuation.yield(.reasoningEnd(
            contentIndex: idx,
            text: reasoningContent.text ?? "",
            partial: partial(),
          ))
        }

        continuation.yield(.done(partial(), AssistantMessageMetadata(stopReason: stopReason, usage: usage)))
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }

    continuation.onTermination = { @Sendable _ in
      task.cancel()
    }
  }
}

// MARK: - Helpers

private func parseGeminiResponse(_ text: String) -> [OrderedDictionary<String, JSONValue>]? {
  let trimmed = text[...].trimmedWhitespace
  guard !trimmed.isEmpty else { return nil }
  switch JSONValue.parse(String(trimmed)) {
  case let .array(values):
    return values.compactMap(\.object)
  case let .object(object):
    return [object]
  default:
    return nil
  }
}

private func parseGeminiUsage(from dict: OrderedDictionary<String, JSONValue>) -> Usage {
  let input = dict["promptTokenCount"]?.intValue ?? 0
  let outputTokens = dict["candidatesTokenCount"]?.intValue ?? 0
  let total = dict["totalTokenCount"]?.intValue ?? (input + outputTokens)
  let reasoning = dict["thoughtsTokenCount"]?.intValue ?? 0
  let cached = dict["cachedContentTokenCount"]?.intValue ?? 0

  return Usage(
    inputTokens: input,
    outputTokens: outputTokens,
    cacheReadTokens: cached,
    cacheWriteTokens: 0,
    reasoningTokens: reasoning,
    totalTokens: total,
  )
}

private func applyGeminiFinishReason(
  _ content: inout [ContentBlock],
  _ currentTextIndex: inout Int?,
  _ currentReasoningIndex: inout Int?,
  _ currentToolCallIndex: inout Int?,
  _ continuation: AsyncThrowingStream<InferenceEvent, any Error>.Continuation,
) {
  func partial() -> AssistantMessage {
    AssistantMessage(content: content, phase: nil)
  }

  if let idx = currentTextIndex, idx < content.count,
     case let .text(part) = content[idx]
  {
    continuation.yield(.textEnd(
      contentIndex: idx,
      text: part.text,
      partial: partial(),
    ))
    currentTextIndex = nil
  }
}

private func mapGeminiFinishReason(_ reason: String) -> StopReason {
  switch reason {
  case "STOP", "MALFORMED_FUNCTION_CALL", "OTHER": return .stop
  case "MAX_TOKENS": return .maxTokens
  case "SAFETY", "RECITATION": return .refusal
  case "FUNCTION_CALL": return .stop
  default: return .stop
  }
}

private extension ContentBlock {
  var toolCall: ToolCall? {
    if case let .toolCall(tc) = self { return tc }
    return nil
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
