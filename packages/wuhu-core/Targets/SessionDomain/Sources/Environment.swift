import Foundation

public enum Nag: Hashable, Sendable, Codable {
  case owedReply(conversations: [ConversationID])
  case park(request: RequestID)

  init?(_ notification: SystemNotification) {
    switch notification.kind {
    case .owedReply:
      self = .owedReply(conversations: notification.conversations)
    case .parkReminder:
      guard let request = notification.requestID else { return nil }
      self = .park(request: request)
    case .timer, .spaceObservation, .compactRequest, .childFailed, .requestDeadline, .script, .context:
      return nil
    }
  }

  public func notification(id: UUID, at timestamp: Date) -> SystemNotification {
    switch self {
    case let .owedReply(conversations):
      SystemNotification(
        id: id, timestamp: timestamp, kind: .owedReply, subscriptionID: .owedReply, conversations: conversations,
        content: .init(text: SessionPrompt.owedReply(conversations: conversations.map(\.rawValue))),
      )
    case let .park(request):
      SystemNotification(
        id: id, timestamp: timestamp, kind: .parkReminder, subscriptionID: .park(request), requestID: request,
        content: .init(text: SessionPrompt.parkReminder(request: request.rawValue)),
      )
    }
  }

  public func rendered(at timestamp: Date) -> String {
    let shown = notification(id: UUID(), at: timestamp)
    return shown.header.render() + "\n\n" + shown.content.text
  }
}

// The session environment: one fold over what a session was shown and what
// its tools did, the settle state and the tool state together. It is reduced
// in log order from stored effects, so it never depends on when anything ran.
//
// Order: requests merge through a tombstone set and subscriptions and file
// reads by key, so parallel tool results commute. The owed map does not
// commute (a delivery sets it, a post clears it): it is ordered by log
// position, which is what the caller's event order is.
public struct SessionEnvironment: Hashable, Sendable, Codable {
  public enum Event: Hashable, Sendable {
    case delivered(QueueInput, at: Date)
    case toolResult(ToolResultPayload, at: Date)
    case nagged(Nag, at: Date)
  }

  public private(set) var settle: SettleState = .init()
  public private(set) var tools: ToolExecutionState = .init()

  public init() {}

  // A head that recorded its settle state already holds the tail it carried
  // across, so the carried items touch only the tool state.
  init(folding transcript: Transcript) {
    let carried = if case let .generationHead(head)? = transcript.items.first, head.settle != nil {
      1 ..< max(1, transcript.keptCount)
    } else {
      0 ..< 0
    }
    for (position, item) in transcript.items.enumerated() {
      guard carried.contains(position) else {
        apply(item)
        continue
      }
      let settled = settle
      apply(item)
      settle = settled
    }
  }

  public mutating func apply(_ event: Event) {
    switch event {
    case let .delivered(input, at):
      if case var .delivered(delivered)? = input.settleEvent {
        delivered.at = at
        settle.apply(.delivered(delivered))
      }
      tools.apply(delivered: input)
    case let .toolResult(payload, at):
      tools.apply(payload)
      switch payload {
      case let .sendMessage(result):
        settle.apply(.posted(.init(conversation: result.conversationID, kind: .message, at: at)))
      case let .report(result):
        settle.apply(.posted(.init(conversation: result.conversationID, kind: result.kind, request: result.requestID, at: at)))
      default:
        break
      }
    case let .nagged(.owedReply(conversations), at):
      settle.apply(.owedReminder(conversations: conversations, at: at))
    case let .nagged(.park(request), at):
      settle.apply(.parkReminder(request: request, at: at))
    }
  }

  // A generation head resets the fold. A head that recorded no settle state
  // was written by the store, which fills it in when it hydrates a session.
  mutating func apply(_ item: TranscriptItem) {
    switch item {
    case .direct, .assistant, .bookmark:
      break
    case let .message(message):
      apply(.delivered(.message(message), at: message.timestamp))
    case let .notification(notification):
      if let nag = Nag(notification) {
        apply(.nagged(nag, at: notification.timestamp))
      } else {
        apply(.delivered(.notification(notification), at: notification.timestamp))
      }
    case let .toolResult(result):
      apply(.toolResult(result.payload, at: result.timestamp))
    case let .generationHead(head):
      settle = head.settle ?? SettleState()
      tools = ToolExecutionState(resuming: head.snapshot)
    }
  }

  // Only a timer or a deadline on a request to a child is certain to fire; an
  // observation is not, and a running exec holds the turn open instead.
  var hasArmedWake: Bool {
    tools.subscriptions.values.contains {
      switch $0 {
      case .timer, .requestDeadline: true
      case .observe: false
      }
    }
  }

  // An agent owes replies in its conversations; any session a parent opened a
  // request on, agent or task, owes that request its final report.
  public func nag(task: Bool, now: Date) -> Nag? {
    if !task, !settle.owedConversations.isEmpty {
      return .owedReply(conversations: settle.owedConversations)
    }
    guard !hasArmedWake else { return nil }
    return settle.openRequests.values.sorted { $0.id.rawValue < $1.id.rawValue }
      .first { ParkBackoff.nextFire(after: $0, now: now) == now }
      .map { .park(request: $0.id) }
  }

  public func nextTimer(now: Date) -> Date? {
    guard !hasArmedWake else { return nil }
    return settle.openRequests.values.compactMap { ParkBackoff.nextFire(after: $0, now: now) }.min()
  }
}
