import SessionDomain
import WuhuAI

extension InferenceExecutor {
  /// The one named exception to carrying thinking as configured: Claude's API
  /// requires its own signed thinking at the start of a thinking-enabled tool
  /// continuation, so after a switch onto Claude mid-tool-loop (a carried tool
  /// call without same-scope signed thinking) the rest of that turn runs without
  /// thinking. Every other provider keeps its configured effort.
  func reasoning(for transcript: Transcript) -> ReasoningOptions {
    let configured: ReasoningOptions = model.specifier.effort == "none" && model.endpoint is any AnthropicMessagesEndpoint ? .none : .effort(model.specifier.effort)
    guard model.isClaude,
          let endpoint = model.endpoint as? any AnthropicMessagesEndpoint,
          let scope = endpoint.replayScope
    else { return configured }

    for (index, item) in transcript.items.enumerated().reversed() {
      switch item {
      case .direct, .message:
        return configured
      case let .notification(notice):
        if notice.kind == .context, notice.content.text.isEmpty { continue }
        if continuesPortableTurn(notice) { continue }
        return configured
      case let .assistant(entry) where index < transcript.keptCount && !entry.toolCalls.isEmpty:
        guard case let .reasoning(.encrypted(thinking))? = entry.content.first,
              thinking.providerID == endpoint.providerID,
              thinking.replayScope == scope,
              thinking.redacted || !thinking.opaque.isEmpty
        else { return .none }
      default:
        break
      }
    }
    return configured
  }
}

private func continuesPortableTurn(_ notice: SystemNotification) -> Bool {
  guard notice.kind == .context else { return false }
  switch notice.subscriptionID.rawValue {
  case "replay-handoff", "model-route": return true
  case "context":
    // dev.117 persisted boundary notices before they had distinct source IDs.
    return notice.content.text.hasPrefix("Portable replay handoff completed. ") ||
      (notice.content.text.hasPrefix("Model group ") && notice.content.text.hasSuffix("Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."))
  default: return false
  }
}

extension ModelSpecifier {
  /// Whether a model id names Claude (``WuhuAI/isClaudeModel(_:)``), whatever
  /// the host or dialect.
  public static func isClaudeModel(_ model: String) -> Bool {
    WuhuAI.isClaudeModel(model)
  }
}
