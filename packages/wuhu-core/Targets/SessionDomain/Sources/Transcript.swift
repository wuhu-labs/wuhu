import Dependencies
import Foundation
import WuhuAI

public struct Transcript: Hashable, Sendable, Codable {
  public var items: [TranscriptItem]
  // Items below keptCount were carried from the parent generation; their
  // usage was inferred against the pre-compaction context.
  public var keptCount: Int
  public var registeredSubscriptions: Set<SubscriptionID>? = nil
  public var handlerSubscriptions: Set<SubscriptionID> = []
  // The ids of the work running for the session right now, read before each
  // inference and rendered as the head's `running:` line.
  public var runningWork: [String]? = nil

  // A reading of the running work is not transcript content: two
  // transcripts that differ only in it are the same.
  public static func == (lhs: Transcript, rhs: Transcript) -> Bool {
    lhs.items == rhs.items && lhs.keptCount == rhs.keptCount
      && lhs.registeredSubscriptions == rhs.registeredSubscriptions && lhs.handlerSubscriptions == rhs.handlerSubscriptions
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(items)
    hasher.combine(keptCount)
    hasher.combine(registeredSubscriptions)
    hasher.combine(handlerSubscriptions)
  }

  enum CodingKeys: String, CodingKey {
    case items
    case keptCount
  }

  public init(
    items: [TranscriptItem] = [], keptCount: Int = 0,
    registeredSubscriptions: Set<SubscriptionID>? = nil, handlerSubscriptions: Set<SubscriptionID> = [],
    runningWork: [String]? = nil,
  ) {
    self.items = items
    self.keptCount = keptCount
    self.registeredSubscriptions = registeredSubscriptions
    self.handlerSubscriptions = handlerSubscriptions
    self.runningWork = runningWork
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
    if let registeredSubscriptions {
      head.snapshot.subscriptions = registeredSubscriptionState(head.snapshot.subscriptions, registered: registeredSubscriptions)
    }
    let keptItems = kept.map { items[$0].filter { item in
      guard case let .notification(notification) = item else { return true }
      return notification.kind != .context || notification.subscriptionID != SubscriptionID("context-pressure")
    } } ?? []
    let carried = [TranscriptItem.generationHead(head)] + keptItems
    return Transcript(
      items: carried, keptCount: carried.count,
      registeredSubscriptions: registeredSubscriptions, handlerSubscriptions: handlerSubscriptions,
      runningWork: runningWork,
    )
  }

  // Everything before the returned index gets summarized; nil = nothing fits,
  // summarize the whole transcript. Never cuts at a tool result: its call
  // would be summarized away, orphaning the result.
  public func compactionCutIndex(keptTokens: Int, images: ImageLimits) -> Int? {
    var firstKeptIndex: Int?
    var sum = 0
    var index = items.count - 1
    while index >= 0 {
      sum += items[index].estimatedTokens(images)
      if case .toolResult = items[index] {
        index -= 1
        continue
      }
      guard sum <= keptTokens else { break }
      firstKeptIndex = index
      index -= 1
    }
    return firstKeptIndex
  }
}
