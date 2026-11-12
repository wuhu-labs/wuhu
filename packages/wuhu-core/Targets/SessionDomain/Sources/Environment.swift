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
    case .timer, .spaceObservation, .compactRequest, .requestStall, .script, .exec, .context:
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

/// What an item changes of what a session owes and of what its tools go by.
enum SessionEvent: Hashable, Sendable {
  case delivered(QueueInput, at: Date)
  case toolResult(ToolResultPayload, at: Date)
  case nagged(Nag, at: Date)

  init?(_ item: TranscriptItem) {
    switch item {
    case .assistant, .bookmark, .generationHead:
      return nil
    case let .message(message):
      self = .delivered(.message(message), at: message.timestamp)
    case let .notification(notification):
      self = Nag(notification).map { .nagged($0, at: notification.timestamp) } ?? .delivered(.notification(notification), at: notification.timestamp)
    case let .toolResult(result):
      self = .toolResult(result.payload, at: result.timestamp)
    }
  }
}

extension ToolExecutionState {
  public mutating func apply(_ item: TranscriptItem) {
    switch SessionEvent(item) {
    case let .delivered(input, _)?: apply(delivered: input)
    case let .toolResult(payload, _)?: apply(payload)
    case .nagged?, nil: break
    }
  }
}

/// What a session's nags follow from: the replies it owes, and how often it was reminded of each request it has not reported on.
public struct NagState: Hashable, Sendable, Codable {
  public var settle: SettleState
  var parks: [RequestID: ParkReminders] = [:]

  public init(settle: SettleState = .init()) {
    self.settle = settle
  }

  public mutating func apply(_ item: TranscriptItem) {
    if let event = SessionEvent(item) { apply(event) }
  }

  private mutating func apply(_ event: SessionEvent) {
    switch event {
    case let .delivered(input, at):
      if case var .delivered(delivered)? = input.settleEvent {
        delivered.at = at
        settle.apply(.delivered(delivered))
      }
    case let .toolResult(.sendMessage(result), at):
      settle.apply(.posted(.init(conversation: result.conversationID, at: at)))
    case let .toolResult(.report(result), at):
      settle.apply(.posted(.init(conversation: result.conversationID, at: at)))
    case .toolResult:
      break
    case let .nagged(.owedReply(conversations), at):
      settle.apply(.owedReminder(conversations: conversations, at: at))
    case let .nagged(.park(request), at):
      parks[request] = ParkReminders(count: (parks[request]?.count ?? 0) + 1, last: at.timeIntervalSinceReferenceDate)
    }
  }

  // An agent owes replies in its conversations; any session a parent opened a
  // request on, agent or task, owes that request its final report. `armedWake`:
  // the session has a plain timer armed, which will wake the model by itself.
  public func nag(task: Bool, openRequests: [OpenRequest], armedWake: Bool, now: Date) -> Nag? {
    if !task, !settle.owedConversations.isEmpty {
      return .owedReply(conversations: settle.owedConversations)
    }
    guard !armedWake else { return nil }
    return openRequests.sorted { $0.id.rawValue < $1.id.rawValue }
      .first { nextParkReminder($0, now: now) == now }
      .map { .park(request: $0.id) }
  }

  public func nextTimer(openRequests: [OpenRequest], armedWake: Bool, now: Date) -> Date? {
    guard !armedWake else { return nil }
    return openRequests.map { nextParkReminder($0, now: now) }.min()
  }

  private func nextParkReminder(_ request: OpenRequest, now: Date) -> Date {
    ParkBackoff.nextFire(reminded: parks[request.id], now: now)
  }
}
