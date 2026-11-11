import Dependencies
import Foundation
import WuhuAI

public struct Transcript: Hashable, Sendable, Codable {
  public var items: [TranscriptItem]
  // Items below keptCount were carried from the parent generation; their
  // usage was inferred against the pre-compaction context.
  public var keptCount: Int

  public init(items: [TranscriptItem] = [], keptCount: Int = 0) {
    self.items = items
    self.keptCount = keptCount
  }

  public var environment: SessionEnvironment {
    SessionEnvironment(folding: self)
  }

  public mutating func append(_ item: TranscriptItem) {
    items.append(item)
  }

  @discardableResult
  public mutating func appendAssistant(
    _ message: AssistantMessage,
    id: UUID,
    metadata: AssistantMessageMetadata,
    replayBinding: ReplayBinding? = nil,
  ) -> AssistantEntry {
    guard let usage = metadata.usage else {
      preconditionFailure("assistant message committed without a usage block")
    }
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    var toolCallIDs: [String: ToolCallID] = [:]
    let content = message.content.map { block -> ContentBlock in
      guard case var .toolCall(call) = block else { return block }
      precondition(toolCallIDs[call.id] == nil, "duplicate provider tool call id \(call.id)")
      let kernelID = ToolCallID(uuid().uuidString.lowercased())
      toolCallIDs[call.id] = kernelID
      call.id = kernelID.rawValue
      return .toolCall(call)
    }

    let entry = AssistantEntry(
      id: id,
      timestamp: date.now,
      content: content,
      stopReason: metadata.stopReason,
      usage: usage,
      toolCallIDs: toolCallIDs,
      replayBinding: replayBinding,
    )
    items.append(.assistant(entry))
    return entry
  }

  public func compacted(head: GenerationHead, kept: Range<Int>?) -> Transcript {
    var head = head
    head.replayBinding = head.replayBinding ?? replayBinding
    let keptItems = kept.map { items[$0].filter { item in
      guard case let .notification(notification) = item else { return true }
      return notification.kind != .context || notification.subscriptionID != SubscriptionID("context-pressure")
    } } ?? []
    let carried = [TranscriptItem.generationHead(head)] + keptItems
    return Transcript(items: carried, keptCount: carried.count)
  }

  // Everything before the returned index gets summarized; nil = nothing fits,
  // summarize the whole transcript. The cut never falls inside a tool turn:
  // every answer it keeps has its call kept too.
  public func compactionCutIndex(keptTokens: Int, images: ImageLimits) -> Int? {
    var firstKeptIndex: Int?
    var sum = 0
    var answersAwaitingCall: Set<ToolCallID> = []
    for index in items.indices.reversed() {
      let item = items[index]
      sum += item.estimatedTokens(images)
      if let callID = item.answeredToolCallID { answersAwaitingCall.insert(callID) }
      if case let .assistant(entry) = item { answersAwaitingCall.subtract(entry.toolCalls.map { ToolCallID($0.id) }) }
      guard answersAwaitingCall.isEmpty else { continue }
      guard sum <= keptTokens else { break }
      firstKeptIndex = index
    }
    return firstKeptIndex
  }
}
