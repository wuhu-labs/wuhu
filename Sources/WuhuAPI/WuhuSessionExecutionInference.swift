import Foundation

public enum WuhuSessionExecutionState: String, Sendable, Hashable, Codable {
  case idle
  case executing
  case stopped
}

public struct WuhuSessionExecutionInference: Sendable, Hashable {
  public var state: WuhuSessionExecutionState
  public var awaitingAssistant: Bool
  public var pendingToolCallIds: Set<String>
  public var pendingToolExecutionIds: Set<String>

  public init(
    state: WuhuSessionExecutionState,
    awaitingAssistant: Bool,
    pendingToolCallIds: Set<String>,
    pendingToolExecutionIds: Set<String>,
  ) {
    self.state = state
    self.awaitingAssistant = awaitingAssistant
    self.pendingToolCallIds = pendingToolCallIds
    self.pendingToolExecutionIds = pendingToolExecutionIds
  }

  public static func infer(from transcript: [WuhuSessionEntry]) -> WuhuSessionExecutionInference {
    var awaitingAssistant = false
    var pendingToolCallIds: Set<String> = []
    var pendingToolExecutionIds: Set<String> = []
    var didStopMostRecentRun = false

    for entry in transcript {
      switch entry.payload {
      case let .message(m):
        switch m {
        case .user:
          didStopMostRecentRun = false
          awaitingAssistant = true

        case let .assistant(a):
          didStopMostRecentRun = false
          let toolCallIds = a.content.compactMap { block -> String? in
            guard case let .toolCall(id, _, _) = block else { return nil }
            return id
          }
          if toolCallIds.isEmpty {
            awaitingAssistant = false
          } else {
            awaitingAssistant = true
            for id in toolCallIds {
              pendingToolCallIds.insert(id)
            }
          }

        case let .toolResult(t):
          didStopMostRecentRun = false
          pendingToolCallIds.remove(t.toolCallId)
          awaitingAssistant = true

        case let .customMessage(c):
          if c.customType == WuhuCustomMessageTypes.executionStopped {
            didStopMostRecentRun = true
            awaitingAssistant = false
            pendingToolCallIds = []
            pendingToolExecutionIds = []
          }

        case .unknown:
          break
        }

      case let .toolExecution(t):
        didStopMostRecentRun = false
        switch t.phase {
        case .start:
          pendingToolExecutionIds.insert(t.toolCallId)
        case .end:
          pendingToolExecutionIds.remove(t.toolCallId)
        }

      case .header, .compaction, .sessionSettings, .custom, .unknown:
        break
      }
    }

    if didStopMostRecentRun {
      return .init(
        state: .stopped,
        awaitingAssistant: false,
        pendingToolCallIds: [],
        pendingToolExecutionIds: [],
      )
    }

    let isExecuting = awaitingAssistant || !pendingToolCallIds.isEmpty || !pendingToolExecutionIds.isEmpty
    return .init(
      state: isExecuting ? .executing : .idle,
      awaitingAssistant: awaitingAssistant,
      pendingToolCallIds: pendingToolCallIds,
      pendingToolExecutionIds: pendingToolExecutionIds,
    )
  }
}
