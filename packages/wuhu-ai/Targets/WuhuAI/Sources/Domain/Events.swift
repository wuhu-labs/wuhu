// MARK: - InferenceEvent

/// Per-block lifecycle events with stable contentIndex.
/// The consumer renders by index, never by type-guessing.
public enum InferenceEvent: Hashable, Sendable {
  /// Stream begins. The partial message carries content and phase.
  case start(AssistantMessage)

  // MARK: Text events

  case textStart(contentIndex: Int, partial: AssistantMessage)
  case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
  case textEnd(contentIndex: Int, text: String, partial: AssistantMessage)

  // MARK: Reasoning events

  case reasoningStart(contentIndex: Int, partial: AssistantMessage)
  case reasoningDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
  case reasoningEnd(contentIndex: Int, text: String, partial: AssistantMessage)

  // MARK: Tool call events

  case toolCallStart(contentIndex: Int, partial: AssistantMessage)
  case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
  case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)

  case usage(Usage, servedModel: String?, partial: AssistantMessage)

  // MARK: Terminal events

  /// Success terminal — carries the final message and metadata.
  case done(AssistantMessage, AssistantMessageMetadata)
}
