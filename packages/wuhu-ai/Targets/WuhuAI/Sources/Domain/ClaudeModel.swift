/// Whether a model id names Claude: one of its tokens split on anything but
/// letters and digits is `claude` (`claude-opus-5-5[1m]`,
/// `anthropic/claude-sonnet-4-6`, `us.anthropic.claude-…`). The host and
/// dialect never enter it, so a proxy serving Claude is under Claude's rules
/// and a non-Claude model on a Claude-format host is not.
public func isClaudeModel(_ model: String) -> Bool {
  model.lowercased().split { !$0.isLetter && !$0.isNumber }.contains("claude")
}
