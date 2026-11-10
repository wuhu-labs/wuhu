#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections

// MARK: - Chat Completions Stream Parser

/// Parse Chat Completions SSE stream into InferenceEvent domain events.
func parseChatCompletionsStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
  replayScope: String? = nil,
) -> AsyncThrowingStream<InferenceEvent, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      var content: [ContentBlock] = []
      let phase: AssistantMessagePhase? = nil
      var stopReason: StopReason = .stop
      var servedModel: String?
      var usage: Usage?

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var toolCalls: [Int: (contentIndex: Int, id: String, name: String, arguments: String)] = [:]
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

      func finishToolCalls() {
        for call in toolCalls.values.sorted(by: { $0.contentIndex < $1.contentIndex }) {
          let toolCall = ToolCall(
            id: call.id,
            name: call.name,
            arguments: ToolArguments(emitted: call.arguments),
          )
          content[call.contentIndex] = .toolCall(toolCall)
          continuation.yield(.toolCallEnd(contentIndex: call.contentIndex, toolCall: toolCall, partial: partial()))
        }
        toolCalls = [:]
      }

      do {
        for try await sseEvent in sse {
          if sseEvent.data[...].trimmedWhitespace == "[DONE]" {
            sawDoneMarker = true
            break
          }

          guard let dict = parseChatJSON(sseEvent.data) else { continue }
          if dict["error"]?.object?["code"]?.stringValue == "upstream_stream_cut" || dict["error"]?.object?["type"]?.stringValue == "upstream_stream_cut" { throw InferenceError.streamCut }
          if let reported = dict["model"]?.stringValue { servedModel = reported }

          // DashScope delivers usage in a trailing chunk whose choices array
          // is empty, so this must run before the choices guard.
          if let usageDict = dict["usage"]?.object {
            let current = parseUsage(from: usageDict)
            usage = current
            continuation.yield(.usage(current, servedModel: servedModel, partial: partial()))
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
                      replayScope: replayScope,
                    ))))
                    currentReasoningIndex = content.count - 1
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

            // Continuation chunks repeat the wire `index` but may carry no id
            // (MiniMax) or an empty one (Kimi on Bailian).
            for tc in delta["tool_calls"]?.array?.compactMap(\.object) ?? [] {
              guard let key = tc["index"]?.intValue else {
                throw ChatCompletionsStreamError.toolCallDeltaWithoutIndex(JSONValue.object(tc).jsonString())
              }
              let id = tc["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
              let function = tc["function"]?.object
              let name = function?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
              let arguments = function?["arguments"]?.stringValue ?? ""
              if var call = toolCalls[key] {
                if call.name.isEmpty, let name { call.name = name }
                call.arguments += arguments
                toolCalls[key] = call
                if !arguments.isEmpty {
                  continuation.yield(.toolCallDelta(contentIndex: call.contentIndex, delta: arguments, partial: partial()))
                }
              } else {
                closeText()
                closeReasoning()
                let callID = id ?? UUID().uuidString
                content.append(.toolCall(ToolCall(id: callID, name: name ?? "", arguments: .object([:]))))
                toolCalls[key] = (content.count - 1, callID, name ?? "", arguments)
                continuation.yield(.toolCallStart(contentIndex: content.count - 1, partial: partial()))
              }
            }
          }

          // Handle finish
          if let reason = finishReason {
            finishToolCalls()

            closeText()
            closeReasoning()

            stopReason = mapChatCompletionsFinishReason(reason)
          }
        }

        guard sawDoneMarker else {
          throw InferenceError.streamCut
        }

        finishToolCalls()
        closeText()
        closeReasoning()

        if stopReason == .stop,
           content.contains(where: { if case .toolCall = $0 { true } else { false } })
        {
          stopReason = .stop
        }

        continuation.yield(.done(partial(), AssistantMessageMetadata(stopReason: stopReason, usage: usage, servedModel: servedModel)))
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

enum ChatCompletionsStreamError: Error, Sendable, Equatable, CustomStringConvertible {
  case toolCallDeltaWithoutIndex(String)

  var description: String {
    switch self {
    case let .toolCallDeltaWithoutIndex(delta): "chat completions tool-call delta without index: \(delta)"
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
