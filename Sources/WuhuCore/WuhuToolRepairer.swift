import Foundation
import PiAI
import WuhuAPI

enum WuhuToolRepairer {
  static let lostToolResultText =
    "The result for this tool call has been lost. Retry if needed. The tool call might or might not have taken place; for non-idempotent actions, check the current state before continuing."

  static let stoppedToolResultText =
    "Execution was stopped before a result for this tool call was recorded. Retry if needed. The tool call might or might not have taken place; for non-idempotent actions, check the current state before continuing."

  struct Result: Sendable {
    var transcript: [WuhuSessionEntry]
    var repairEntries: [WuhuSessionEntry]
  }

  enum Mode: Sendable {
    case lost
    case stopped
  }

  static func repairMissingToolResultsIfNeeded(
    sessionID: String,
    transcript: [WuhuSessionEntry],
    mode: Mode,
    store: any SessionStore,
    eventHub: WuhuLiveEventHub,
  ) async throws -> Result {
    var pendingOrder: [String] = []
    var pendingNames: [String: String] = [:]

    var lastMessage: Message?

    for entry in transcript {
      guard case let .message(m) = entry.payload else { continue }
      guard let pi = m.toPiMessage() else { continue }
      lastMessage = pi
      switch pi {
      case let .assistant(a):
        for block in a.content {
          guard case let .toolCall(call) = block else { continue }
          if pendingNames[call.id] == nil {
            pendingOrder.append(call.id)
          }
          pendingNames[call.id] = call.name
        }
      case let .toolResult(r):
        pendingNames[r.toolCallId] = nil
        pendingOrder.removeAll(where: { $0 == r.toolCallId })
      case .user:
        break
      }
    }

    guard !pendingOrder.isEmpty else {
      return Result(transcript: transcript, repairEntries: [])
    }

    // Only persist a repair when the transcript ends with an assistant tool-call message.
    guard case let .assistant(lastAssistant) = lastMessage else {
      return Result(transcript: transcript, repairEntries: [])
    }
    let lastAssistantToolCallIDs = Set(lastAssistant.content.compactMap { block -> String? in
      if case let .toolCall(call) = block { return call.id }
      return nil
    })
    guard !lastAssistantToolCallIDs.isEmpty,
          pendingOrder.allSatisfy({ lastAssistantToolCallIDs.contains($0) })
    else {
      return Result(transcript: transcript, repairEntries: [])
    }

    var updatedTranscript = transcript
    var repairEntries: [WuhuSessionEntry] = []

    for toolCallId in pendingOrder {
      guard let toolName = pendingNames[toolCallId] else { continue }

      let reason = switch mode {
      case .lost:
        "lost"
      case .stopped:
        "stopped"
      }
      let text: String = switch mode {
      case .lost:
        Self.lostToolResultText
      case .stopped:
        Self.stoppedToolResultText
      }

      let repaired: Message = .toolResult(.init(
        toolCallId: toolCallId,
        toolName: toolName,
        content: [.text(text)],
        details: .object([
          "wuhu_repair": .string("missing_tool_result"),
          "reason": .string(reason),
        ]),
        isError: true,
      ))

      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.fromPi(repaired)))
      updatedTranscript.append(entry)
      repairEntries.append(entry)
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))
    }

    return Result(transcript: updatedTranscript, repairEntries: repairEntries)
  }

  static func repairMissingToolResultsInMemory(_ messages: [Message]) -> [Message] {
    var repaired: [Message] = []
    repaired.reserveCapacity(messages.count)

    var pendingOrder: [String] = []
    var pendingNames: [String: String] = [:]

    func injectMissingToolResults(timestamp: Date) {
      guard !pendingOrder.isEmpty else { return }
      for toolCallId in pendingOrder {
        guard let toolName = pendingNames[toolCallId] else { continue }
        repaired.append(.toolResult(.init(
          toolCallId: toolCallId,
          toolName: toolName,
          content: [.text(Self.lostToolResultText)],
          details: .object([
            "wuhu_repair": .string("missing_tool_result"),
            "reason": .string("lost"),
          ]),
          isError: true,
          timestamp: timestamp,
        )))
      }
      pendingOrder = []
      pendingNames = [:]
    }

    for msg in messages {
      switch msg {
      case let .toolResult(r):
        repaired.append(msg)
        if pendingNames[r.toolCallId] != nil {
          pendingNames[r.toolCallId] = nil
          pendingOrder.removeAll(where: { $0 == r.toolCallId })
        }

      case let .assistant(a):
        if !pendingOrder.isEmpty {
          injectMissingToolResults(timestamp: msg.timestamp)
        }
        repaired.append(msg)
        for block in a.content {
          guard case let .toolCall(call) = block else { continue }
          if pendingNames[call.id] == nil {
            pendingOrder.append(call.id)
          }
          pendingNames[call.id] = call.name
        }

      case .user:
        if !pendingOrder.isEmpty {
          injectMissingToolResults(timestamp: msg.timestamp)
        }
        repaired.append(msg)
      }
    }

    if !pendingOrder.isEmpty {
      injectMissingToolResults(timestamp: messages.last?.timestamp ?? Date())
    }

    return repaired
  }
}
