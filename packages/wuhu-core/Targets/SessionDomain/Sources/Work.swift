import Foundation
import struct WuhuAI.ToolCall

extension TranscriptItem: Identifiable {
  public var id: UUID {
    switch self {
    case let .direct(message): message.id
    case let .message(message): message.id
    case let .notification(notification): notification.id
    case let .assistant(entry): entry.id
    case let .toolResult(result): result.id
    case let .bookmark(marker): marker.id
    case let .generationHead(head): head.id
    }
  }
}

extension Transcript {
  public var pendingToolCallIDs: [ToolCallID] {
    var minted: [ToolCallID] = []
    var satisfied: Set<ToolCallID> = []
    for item in items {
      switch item {
      case let .assistant(entry):
        minted.append(contentsOf: entry.toolCalls.map { ToolCallID($0.id) })
      case let .toolResult(result):
        if case let .toolCall(callID) = result.provenance { satisfied.insert(callID) }
      case let .bookmark(marker):
        if let callID = marker.toolCallID { satisfied.insert(callID) }
      case .direct, .message, .notification, .generationHead:
        break
      }
    }
    return minted.filter { !satisfied.contains($0) }
  }

  public var hasWork: Bool {
    guard let last = items.last else { return false }
    if !pendingToolCallIDs.isEmpty { return true }
    switch last {
    case .assistant:
      return false
    case let .generationHead(head):
      // A head that folded nothing and asks for no re-establishment — a fresh
      // session, a restart — leaves the session with nothing to answer. A
      // compaction's head always carries a summary and drives the next turn.
      return !head.summary.isEmpty || !head.snapshot.isEmpty
    default:
      return true
    }
  }

  public var nextPendingToolCall: ToolCall? {
    guard let pending = pendingToolCallIDs.first else { return nil }
    for item in items {
      guard case let .assistant(entry) = item else { continue }
      if let call = entry.toolCalls.first(where: { $0.id == pending.rawValue }) {
        return call
      }
    }
    preconditionFailure("pending tool call id \(pending.rawValue) has no originating call")
  }

  // Settled once the generation contains a FRESH assistant message
  // (index >= keptCount): carried-tail assistant entries predate the head and
  // prove nothing about re-establishment.
  public var needsReestablishment: Bool {
    guard case let .generationHead(head) = items.first else { return false }
    guard !head.snapshot.preReads.isEmpty else { return false }
    return !items[keptCount...].contains { item in
      if case .assistant = item { return true } else { return false }
    }
  }
}
