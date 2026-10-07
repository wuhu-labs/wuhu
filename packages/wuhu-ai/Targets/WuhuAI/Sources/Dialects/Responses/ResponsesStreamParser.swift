#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections

// MARK: - Responses Stream Parser

/// Parse OpenAI Responses SSE stream into InferenceEvent domain events.
func parseResponsesStream<Events: AsyncSequence & Sendable>(
  _ sse: Events,
  providerID: String,
  model: String,
  finiteResponse: Bool = false,
) -> AsyncThrowingStream<InferenceEvent, any Error> where Events.Element == SSEEvent {
  AsyncThrowingStream { continuation in
    let task = Task {
      var content: [ContentBlock] = []
      var phase: AssistantMessagePhase?
      var stopReason: StopReason = .stop
      var servedModel: String?
      var usage: Usage?
      var completedStatus: String?

      func partial() -> AssistantMessage {
        AssistantMessage(content: content, phase: phase)
      }

      func completedMessage() -> AssistantMessage {
        AssistantMessage(content: content.filter { !isVacuousReasoning($0) }, phase: phase)
      }

      continuation.yield(.start(partial()))

      var currentTextIndex: Int?
      var currentToolCallIndex: Int?
      var currentToolCallID: String?
      var currentToolCallName: String?
      var currentToolCallArguments: String = ""
      var reasoningIndexByID: [String: Int] = [:]
      var sawResponseCompleted = false
      var toolStates: [String: (index: Int?, id: String?, name: String?, arguments: String)] = [:]

      do {
        for try await sseEvent in sse {
          guard let dict = parseJSON(sseEvent.data) else { continue }
          guard let type = dict["type"]?.stringValue else { continue }

          if let reported = dict["response"]?.object?["model"]?.stringValue { servedModel = reported }

          if let usageDict = dict["response"]?.object?["usage"]?.object {
            let input = usageDict["input_tokens"]?.intValue ?? 0
            let outputTokens = usageDict["output_tokens"]?.intValue ?? 0
            let total = usageDict["total_tokens"]?.intValue ?? (input + outputTokens)
            let reasoning = usageDict["output_tokens_details"]?.object?["reasoning_tokens"]?.intValue
              ?? usageDict["reasoning_tokens"]?.intValue
            let cacheRead = usageDict["input_tokens_details"]?.object?["cached_tokens"]?.intValue
              ?? usageDict["cached_input_tokens"]?.intValue
              ?? 0
            let cacheWrite = usageDict["input_tokens_details"]?.object?["cache_write_tokens"]?.intValue
              ?? usageDict["cache_creation_input_tokens"]?.intValue
              ?? 0

            let current = Usage(
              inputTokens: input,
              outputTokens: outputTokens,
              cacheReadTokens: cacheRead,
              cacheWriteTokens: cacheWrite,
              reasoningTokens: reasoning,
              totalTokens: total,
            )
            usage = current
            continuation.yield(.usage(current, servedModel: servedModel, partial: partial()))
          }

          let toolItemID = dict["item_id"]?.stringValue ?? dict["item"]?.object?["id"]?.stringValue
          let isToolEvent = type.hasPrefix("response.function_call_arguments.")
            || dict["item"]?.object?["type"]?.stringValue == "function_call"
          if finiteResponse, isToolEvent, let toolItemID,
             let state = toolStates[toolItemID]
          {
            currentToolCallIndex = state.index
            currentToolCallID = state.id
            currentToolCallName = state.name
            currentToolCallArguments = state.arguments
          }

          switch type {
          case "response.output_item.added":
            guard let item = dict["item"]?.object,
                  let itemType = item["type"]?.stringValue
            else { continue }

            if itemType == "message" {
              content.append(.text(TextContent(text: "")))
              currentTextIndex = content.count - 1
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

              // Check for phase
              if let phaseStr = item["phase"]?.stringValue {
                phase = AssistantMessagePhase(rawValue: phaseStr)
              }

              continuation.yield(.textStart(
                contentIndex: currentTextIndex!,
                partial: partial(),
              ))

            } else if itemType == "function_call" {
              // Persist only the Responses `call_id`. The output-item `id`
              // (`fc_…`) is deliberately dropped: it is not required to replay a
              // function call (verified empirically, incl. parallel calls and
              // reasoning under ZDR), and storing it as a compound `call_id|fc_…`
              // produced an ID that other providers' wire formats reject.
              let callID = item["call_id"]?.stringValue ?? UUID().uuidString
              let name = item["name"]?.stringValue ?? "tool"

              content.append(.toolCall(ToolCall(
                id: callID,
                name: name,
                arguments: .object([:]),
              )))
              currentToolCallIndex = content.count - 1
              currentToolCallID = callID
              currentToolCallName = name
              currentToolCallArguments = item["arguments"]?.stringValue ?? ""
              currentTextIndex = nil

              continuation.yield(.toolCallStart(
                contentIndex: currentToolCallIndex!,
                partial: partial(),
              ))

            } else if itemType == "reasoning" {
              let id = item["id"]?.stringValue ?? UUID().uuidString
              let encrypted = item["encrypted_content"]?.stringValue
              let summaryText = parseReasoningSummary(from: item)

              content.append(.reasoning(.encrypted(EncryptedReasoningContent(
                providerID: providerID,
                model: model,
                summary: summaryText,
                opaque: encrypted ?? "",
                id: id,
              ))))
              let idx = content.count - 1
              reasoningIndexByID[id] = idx
              currentTextIndex = nil
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

              continuation.yield(.reasoningStart(
                contentIndex: idx,
                partial: partial(),
              ))

              if let summaryText {
                continuation.yield(.reasoningEnd(
                  contentIndex: idx,
                  text: summaryText,
                  partial: partial(),
                ))
              }
            }

          case "response.output_text.delta":
            guard let delta = dict["delta"]?.stringValue else { continue }
            if let idx = currentTextIndex, idx < content.count,
               case var .text(part) = content[idx]
            {
              part.text += delta
              content[idx] = .text(part)
            } else {
              content.append(.text(TextContent(text: delta)))
              currentTextIndex = content.count - 1
              continuation.yield(.textStart(
                contentIndex: currentTextIndex!,
                partial: partial(),
              ))
            }
            continuation.yield(.textDelta(
              contentIndex: currentTextIndex!,
              delta: delta,
              partial: partial(),
            ))

          case "response.function_call_arguments.delta":
            guard let delta = dict["delta"]?.stringValue else { continue }
            guard currentToolCallIndex != nil else { continue }
            currentToolCallArguments += delta
            continuation.yield(.toolCallDelta(
              contentIndex: currentToolCallIndex!,
              delta: delta,
              partial: partial(),
            ))

          case "response.function_call_arguments.done":
            if let arguments = dict["arguments"]?.stringValue, !arguments.isEmpty {
              currentToolCallArguments = arguments
            }

          case "response.output_item.done":
            guard let item = dict["item"]?.object,
                  let itemType = item["type"]?.stringValue
            else { continue }

            if itemType == "message" {
              if let idx = currentTextIndex, idx < content.count,
                 case var .text(part) = content[idx]
              {
                if finiteResponse, let finalContent = item["content"]?.array {
                  part.text = finalContent.compactMap { part -> String? in
                    switch part.object?["type"]?.stringValue {
                    case "output_text": return part.object?["text"]?.stringValue
                    case "refusal": return part.object?["refusal"]?.stringValue
                    default: return nil
                    }
                  }.joined()
                  content[idx] = .text(part)
                }
                continuation.yield(.textEnd(
                  contentIndex: idx,
                  text: part.text,
                  partial: partial(),
                ))
              }
              currentTextIndex = nil

              // Check for phase
              if let phaseStr = item["phase"]?.stringValue {
                phase = AssistantMessagePhase(rawValue: phaseStr)
              }

            } else if itemType == "function_call" {
              let argsText = currentToolCallArguments.isEmpty
                ? (item["arguments"]?.stringValue ?? "")
                : currentToolCallArguments

              if let idx = currentToolCallIndex, idx < content.count,
                 let id = currentToolCallID, let name = currentToolCallName
              {
                let args = ToolArguments(verbatim: argsText) ?? .object([:])
                let toolCall = ToolCall(id: id, name: name, arguments: args)
                content[idx] = .toolCall(toolCall)
                continuation.yield(.toolCallEnd(
                  contentIndex: idx,
                  toolCall: toolCall,
                  partial: partial(),
                ))
              }
              currentToolCallIndex = nil
              currentToolCallID = nil
              currentToolCallName = nil
              currentToolCallArguments = ""

            } else if itemType == "web_search_call",
                      let payload = dict["item"],
                      let item = HostedToolContent(providerID: providerID, payload: payload)
            {
              content.append(.hostedTool(item))
              currentTextIndex = nil
              currentToolCallIndex = nil

            } else if itemType == "reasoning" {
              let id = item["id"]?.stringValue ?? UUID().uuidString
              let encrypted = nonEmpty(item["encrypted_content"]?.stringValue)
              let summaryText = parseReasoningSummary(from: item)

              if let idx = reasoningIndexByID[id], idx < content.count {
                let existing: EncryptedReasoningContent?
                if case let .reasoning(.encrypted(reasoning)) = content[idx] {
                  existing = reasoning
                } else {
                  existing = nil
                }
                content[idx] = .reasoning(.encrypted(EncryptedReasoningContent(
                  providerID: providerID,
                  model: model,
                  summary: summaryText ?? existing?.summary,
                  opaque: encrypted ?? existing?.opaque ?? "",
                  id: id,
                )))
                if let summaryText {
                  continuation.yield(.reasoningEnd(
                    contentIndex: idx,
                    text: summaryText,
                    partial: partial(),
                  ))
                }
              }
            }

          case "response.completed":
            sawResponseCompleted = true
            if let response = dict["response"]?.object {
              completedStatus = response["status"]?.stringValue

              // Use incomplete_details.reason for stop reason
              if let incomplete = response["incomplete_details"]?.object,
                 let reason = incomplete["reason"]?.stringValue
              {
                stopReason = mapIncompleteReason(reason)
              } else if completedStatus == "completed" {
                stopReason = .stop
              }
            }

          case "response.failed":
            let status = dict["response"]?.object?["status"]?.stringValue ?? type
            throw ResponsesStreamError.failed(status: status)

          case "response.cancelled":
            throw ResponsesStreamError.cancelled

          default:
            break
          }
          if finiteResponse, isToolEvent, let toolItemID {
            toolStates[toolItemID] = (currentToolCallIndex, currentToolCallID, currentToolCallName, currentToolCallArguments)
          }
        }

        guard sawResponseCompleted else {
          throw ProviderStreamError.invalidStream(
            "Responses stream ended before response.completed",
          )
        }

        continuation.yield(.done(completedMessage(), AssistantMessageMetadata(stopReason: stopReason, usage: usage, servedModel: servedModel)))
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

// MARK: - Responses Error

enum ResponsesStreamError: Error {
  case failed(status: String)
  case cancelled
}

// MARK: - Codex Stream Parser

/// Parse OpenAI Codex (Responses variant) SSE stream into domain events.
/// Codex uses the same SSE structure as Responses with minor differences.
func parseCodexStream(
  _ sse: AsyncThrowingStream<SSEEvent, any Error>,
  providerID: String,
  model: String,
) -> AsyncThrowingStream<InferenceEvent, any Error> {
  // Codex uses the same SSE protocol as Responses.
  parseResponsesStream(sse, providerID: providerID, model: model)
}

// MARK: - Helpers

private func isVacuousReasoning(_ block: ContentBlock) -> Bool {
  guard case let .reasoning(.encrypted(reasoning)) = block else { return false }
  return reasoning.opaque.isEmpty && (reasoning.summary?.isEmpty ?? true)
}

private func parseReasoningSummary(from item: OrderedDictionary<String, JSONValue>) -> String? {
  let summary = item["summary"]?.array ?? []
  let summaryText = summary.compactMap { part -> String? in
    guard let p = part.object,
          p["type"]?.stringValue == "summary_text",
          let text = p["text"]?.stringValue
    else { return nil }
    return text
  }.joined(separator: "\n")
  return nonEmpty(summaryText)
}

private func nonEmpty(_ text: String?) -> String? {
  guard let text, !text.isEmpty else { return nil }
  return text
}

private func parseJSON(_ text: String) -> OrderedDictionary<String, JSONValue>? {
  JSONValue.parse(text)?.object
}

private func mapIncompleteReason(_ reason: String) -> StopReason {
  switch reason {
  case "max_output_tokens": return .maxTokens
  case "content_filter": return .refusal
  default: return .stop
  }
}
