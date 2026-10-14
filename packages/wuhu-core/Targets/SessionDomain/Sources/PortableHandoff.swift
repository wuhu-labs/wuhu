import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import WuhuAI

public struct ReplayBinding: Hashable, Sendable, Codable {
  public var identity: String
  public var epoch: String

  public init(identity: String, epoch: String) {
    self.identity = identity
    self.epoch = epoch
  }
}

public enum PortableHandoffError: Error, Equatable, Sendable {
  case outstandingToolCalls
  case modelHandoffTooLarge
}

extension Transcript {
  public var replayBinding: ReplayBinding? {
    for item in items.reversed() {
      switch item {
      case let .assistant(entry):
        if let binding = entry.replayBinding { return binding }
      case let .generationHead(head):
        return head.replayBinding
      default: break
      }
    }
    return nil
  }

  public var hasUnscopedReplay: Bool {
    items.contains { item in
      guard case let .assistant(entry) = item else { return false }
      return entry.content.contains { block in
        switch block {
        case let .reasoning(.encrypted(content)): content.replayScope == nil
        case let .hostedTool(content): content.replayScope == nil
        default: false
        }
      }
    }
  }

  public func requiresReplayHandoff(to identity: String) -> Bool {
    if let replayBinding, replayBinding.identity != identity { return true }
    return items.contains { item in
      guard case let .assistant(entry) = item, entry.replayBinding == nil else { return false }
      return Transcript(items: [item]).hasUnscopedReplay
    }
  }

  public func portableHandoff(binding: ReplayBinding, budget: ContextBudget, recentTokens: Int = 8192) throws -> Transcript {
    guard pendingToolCallIDs.isEmpty else { throw PortableHandoffError.outstandingToolCalls }
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now
    let environment = environment
    let protected = protectedHandoffInputs(environment.settle)
    let projected = items.map { item -> TranscriptItem in
      guard case var .assistant(entry) = item else { return item }
      entry.id = uuid()
      entry.replayBinding = nil
      entry.content = entry.content.compactMap { block in
        switch block {
        case let .reasoning(.encrypted(content)):
          guard !content.redacted, let summary = content.summary, !summary.isEmpty else { return nil }
          return .text(summary)
        case let .hostedTool(content): return .text(content.digest)
        default: return block
        }
      }
      return .assistant(entry)
    }
    let portable = Transcript(items: projected)
    var tailBudget = max(0, recentTokens)
    while true {
      let cut = tailBudget > 0 ? portable.compactionCutIndex(keptTokens: tailBudget, images: budget.images) : nil
      let selected = Set(projected.indices.filter { index in
        switch projected[index] {
        case .generationHead: return false
        case let .notification(notification) where notification.kind == .context && notification.subscriptionID == SubscriptionID("context-pressure"): return false
        default: return protected.contains(index) || (cut.map { index >= $0 } ?? false)
        }
      })
      let folded = projected.indices.filter { !selected.contains($0) }
      let digest = folded.suffix(80).map { portableDigest(projected[$0]) }.joined(separator: "\n")
      let head = GenerationHead(
        id: uuid(), timestamp: now,
        summary: "Mechanical portable handoff: \(folded.count) earlier item(s) folded without model summarization. Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read files/history if needed.\n" + digest,
        snapshot: .init(carrying: environment.tools, preReads: []), settle: environment.settle,
        note: "Replay binding changed or legacy unscoped content was adopted; prior opaque replay was removed.",
        replayBinding: binding,
      )
      let notice = TranscriptItem.notification(SystemNotification(
        id: uuid(), timestamp: now, kind: .context, subscriptionID: .context,
        content: .init(text: "Portable replay handoff completed. Earlier tool calls have their committed receipts; do not execute them again. This is a fresh account-neutral turn. Continue the outstanding request using the full carried input; re-read files/history as needed."),
      ))
      let carried = [TranscriptItem.generationHead(head)] + projected.indices.filter { selected.contains($0) }.map { projected[$0] } + [notice]
      let result = Transcript(items: carried, keptCount: carried.count, registeredSubscriptions: registeredSubscriptions, handlerSubscriptions: handlerSubscriptions)
      if result.items.reduce(0, { $0 + $1.estimatedTokens(budget.images) }) <= budget.usableTokens { return result }
      guard tailBudget > 0 else { throw PortableHandoffError.modelHandoffTooLarge }
      tailBudget = tailBudget > 256 ? tailBudget / 2 : 0
    }
  }

  private func protectedHandoffInputs(_ settle: SettleState) -> Set<Int> {
    var posted: [ConversationID: Int] = [:]
    var lastAssistant = -1
    for (index, item) in items.enumerated() {
      if case .assistant = item { lastAssistant = index }
      guard case let .toolResult(result) = item else { continue }
      switch result.payload {
      case let .sendMessage(receipt): posted[receipt.conversationID] = index
      case let .report(receipt): posted[receipt.conversationID] = index
      default: break
      }
    }
    let protectLatestToolTurn = lastAssistant >= 0 && {
      guard case let .assistant(entry) = items[lastAssistant] else { return false }
      return !entry.toolCalls.isEmpty
    }()
    return Set(items.indices.filter { index in
      if protectLatestToolTurn, index >= lastAssistant { return true }
      switch items[index] {
      case let .message(message):
        if let request = message.requestID, settle.openRequests[request] != nil { return true }
        if settle.owed[message.conversationID] != nil, index > (posted[message.conversationID] ?? -1) { return true }
        return index > lastAssistant
      case .direct, .notification: return index > lastAssistant
      default: return false
      }
    })
  }
}

private func portableDigest(_ item: TranscriptItem) -> String {
  func clip(_ text: String) -> String { String(text.replacingOccurrences(of: "\n", with: " ").prefix(160)) }
  switch item {
  case let .direct(message): return "- direct: " + clip(message.content.text)
  case let .message(message): return "- message \(message.messageID.rawValue): " + clip(message.content.text)
  case let .notification(notification): return "- notification: " + clip(notification.content.text)
  case let .assistant(entry):
    let text = entry.content.compactMap { block -> String? in
      switch block {
      case let .text(content): content.text
      case let .reasoning(.unencrypted(text)): text
      default: nil
      }
    }.joined(separator: " ")
    return "- assistant: " + clip(text)
  case .toolResult: return "- completed kernel tool receipt (retained in history)"
  case let .bookmark(marker): return "- bookmark: " + clip(marker.name ?? "")
  case let .generationHead(head): return "- earlier summary: " + clip(head.summary)
  }
}
