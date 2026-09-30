public struct ClaudeInferenceCalls: Sendable {
  private var pending: ClaudeStreamFrame.Assistant?
  private var completed: Set<String> = []

  public init() {}

  public mutating func record(_ frame: ClaudeStreamFrame) -> [ClaudeStreamFrame.Assistant] {
    switch frame {
    case let .assistant(assistant):
      guard !completed.contains(assistant.id) else { return [] }
      let finished = pending.map { $0.id != assistant.id } == true ? drain() : []
      pending = .init(
        id: assistant.id, timestamp: pending?.timestamp ?? assistant.timestamp,
        model: assistant.model, usage: assistant.usage,
      )
      return finished
    case .result:
      return drain()
    case let .other(value) where value.object?["type"]?.stringValue == "user" || value.object?["type"]?.stringValue == "tool_result":
      return drain()
    default:
      return []
    }
  }

  public mutating func drain() -> [ClaudeStreamFrame.Assistant] {
    guard let pending else { return [] }
    self.pending = nil
    completed.insert(pending.id)
    return [pending]
  }
}
