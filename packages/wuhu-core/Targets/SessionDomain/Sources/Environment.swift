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

// The session environment: one fold over what a session was shown and what
// its tools did, the settle state and the tool state together. It is reduced
// in log order from stored effects, so it never depends on when anything ran.
//
// Order: subscriptions and file reads merge by key, so parallel tool results
// commute. The owed map does not
// commute (a delivery sets it, a post clears it): it is ordered by log
// position, which is what the caller's event order is.
public struct SessionEnvironment: Hashable, Sendable, Codable {
  public enum Event: Hashable, Sendable {
    case delivered(QueueInput, at: Date)
    case toolResult(ToolResultPayload, at: Date)
    case nagged(Nag, at: Date)
  }

  public private(set) var nags: NagState = .init()
  public private(set) var tools: ToolExecutionState = .init()

  public init() {}

  public var settle: SettleState { nags.settle }

  // A head that recorded its settle state already holds the tail it carried
  // across, so the carried items leave it alone.
  init(folding transcript: Transcript) {
    let carried = if case let .generationHead(head)? = transcript.items.first, head.settle != nil {
      1 ..< max(1, transcript.keptCount)
    } else {
      0 ..< 0
    }
    for (position, historical) in transcript.items.enumerated() {
      var item = historical
      if position > 0, position < transcript.keptCount, case var .notification(notice) = item {
        notice.folderRoots = nil
        notice.deliveredContext = nil
        item = .notification(notice)
      }
      guard carried.contains(position) else {
        apply(item)
        continue
      }
      let settled = nags.settle
      apply(item)
      nags.settle = settled
    }
    tools.handlerSubscriptions = transcript.handlerSubscriptions
    if let registered = transcript.registeredSubscriptions {
      tools.subscriptions = registeredSubscriptionState(tools.subscriptions, registered: registered)
    }
  }

  public mutating func apply(_ event: Event) {
    nags.apply(event)
    switch event {
    case let .delivered(input, _): tools.apply(delivered: input)
    case let .toolResult(payload, _): tools.apply(payload)
    case .nagged: break
    }
  }

  // A generation head resets the fold. A head that recorded no settle state
  // was written by the store, which fills it in when it hydrates a session.
  mutating func apply(_ item: TranscriptItem) {
    if case let .generationHead(head) = item {
      nags = NagState(settle: head.settle ?? SettleState())
      tools = ToolExecutionState(resuming: head.snapshot)
    } else if let event = Event(item) {
      apply(event)
    }
  }

  // A handler timer can stay silent; only a plain timer guarantees a model wake.
  var hasArmedWake: Bool {
    tools.subscriptions.contains { id, subscription in
      switch subscription {
      case .timer: !tools.handlerSubscriptions.contains(id)
      case .observe, .stream: false
      }
    }
  }

  // An agent owes replies in its conversations; any session a parent opened a
  // request on, agent or task, owes that request its final report.
  public func nag(task: Bool, openRequests: [OpenRequest], now: Date) -> Nag? {
    if !task, !settle.owedConversations.isEmpty {
      return .owedReply(conversations: settle.owedConversations)
    }
    guard !hasArmedWake else { return nil }
    return openRequests.sorted { $0.id.rawValue < $1.id.rawValue }
      .first { nextParkReminder($0, now: now) == now }
      .map { .park(request: $0.id) }
  }

  public func nextTimer(openRequests: [OpenRequest], now: Date) -> Date? {
    guard !hasArmedWake else { return nil }
    return openRequests.map { nextParkReminder($0, now: now) }.min()
  }

  private func nextParkReminder(_ request: OpenRequest, now: Date) -> Date {
    ParkBackoff.nextFire(reminded: nags.parks[request.id], now: now)
  }
}

extension SessionEnvironment.Event {
  init?(_ item: TranscriptItem) {
    switch item {
    case .direct, .assistant, .bookmark, .generationHead:
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

/// What a session's nags follow from: the replies it owes, and how often it was reminded of each request it has not reported on.
public struct NagState: Hashable, Sendable, Codable {
  public var settle: SettleState
  var parks: [RequestID: ParkReminders] = [:]

  public init(settle: SettleState = .init()) {
    self.settle = settle
  }

  /// A new generation's: what is owed stays as it was, and the reminders counted are the ones in the tail it kept.
  public init(settle: SettleState, kept: some Sequence<TranscriptItem>) {
    self.init()
    for item in kept { apply(item) }
    self.settle = settle
  }

  public mutating func apply(_ item: TranscriptItem) {
    if let event = SessionEnvironment.Event(item) { apply(event) }
  }

  mutating func apply(_ event: SessionEnvironment.Event) {
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
}
