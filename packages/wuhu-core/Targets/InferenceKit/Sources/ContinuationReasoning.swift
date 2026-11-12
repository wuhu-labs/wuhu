import SessionDomain
import WuhuAI

extension InferenceExecutor {
  /// The one named exception to carrying thinking as configured: Claude's API
  /// requires its own signed thinking at the start of a thinking-enabled tool
  /// continuation, so after a switch onto Claude mid-tool-loop (a carried tool
  /// call without same-scope signed thinking) the rest of that turn runs without
  /// thinking. Every other provider keeps its configured effort.
  func reasoning(for lines: [TranscriptLine]) -> ReasoningOptions {
    let configured: ReasoningOptions = model.specifier.effort == "none" && model.endpoint is any AnthropicMessagesEndpoint ? .none : .effort(model.specifier.effort)
    guard model.isClaude,
          let endpoint = model.endpoint as? any AnthropicMessagesEndpoint,
          let scope = endpoint.replayScope
    else { return configured }

    for line in lines.reversed() {
      switch line.message {
      case .user:
        if line.key == "subscription:replay-handoff" || line.key == "subscription:model-route" { continue }
        if line.key.hasPrefix("message:") || line.key.hasPrefix("subscription:") { return configured }
      case let .assistant(reply) where line.meta == nil && reply.content.contains(where: { if case .toolCall = $0 { true } else { false } }):
        guard case let .reasoning(.encrypted(thinking))? = reply.content.first,
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

extension ModelSpecifier {
  /// Whether a model id names Claude (``WuhuAI/isClaudeModel(_:)``), whatever
  /// the host or dialect.
  public static func isClaudeModel(_ model: String) -> Bool {
    WuhuAI.isClaudeModel(model)
  }
}
