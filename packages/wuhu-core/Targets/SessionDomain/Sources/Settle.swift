import Foundation

public enum SettleEvent: Hashable, Sendable {
  case delivered(Delivered)
  case posted(Posted)
  case owedReminder(conversations: [ConversationID], at: Date)
  case parkReminder(request: RequestID, at: Date)

  public struct Delivered: Hashable, Sendable {
    public var conversation: ConversationID
    public var kind: MessageKind
    public var request: RequestID?
    public var deadline: Date?
    // Owed-reply scope, decided by the projection: an agent's own box and its
    // DMs with users, nothing else.
    public var owesReply: Bool
    public var at: Date

    public init(
      conversation: ConversationID,
      kind: MessageKind,
      request: RequestID? = nil,
      deadline: Date? = nil,
      owesReply: Bool,
      at: Date,
    ) {
      self.conversation = conversation
      self.kind = kind
      self.request = request
      self.deadline = deadline
      self.owesReply = owesReply
      self.at = at
    }
  }

  public struct Posted: Hashable, Sendable {
    public var conversation: ConversationID
    public var kind: MessageKind
    public var request: RequestID?
    public var at: Date

    public init(conversation: ConversationID, kind: MessageKind, request: RequestID? = nil, at: Date) {
      self.conversation = conversation
      self.kind = kind
      self.request = request
      self.at = at
    }
  }

  var at: Date {
    switch self {
    case let .delivered(event): event.at
    case let .posted(event): event.at
    case let .owedReminder(_, at): at
    case let .parkReminder(_, at): at
    }
  }

  var tieBreak: Int {
    switch self {
    case .delivered: 0
    case .posted: 1
    case .owedReminder, .parkReminder: 2
    }
  }
}

public struct OpenRequest: Hashable, Sendable, Codable {
  public var id: RequestID
  public var conversation: ConversationID
  public var deadline: Date?
  public var openedAt: Date
  public var lastParkReminderAt: Date?
  public var parkReminderCount: Int

  public init(
    id: RequestID,
    conversation: ConversationID,
    deadline: Date? = nil,
    openedAt: Date,
    lastParkReminderAt: Date? = nil,
    parkReminderCount: Int = 0,
  ) {
    self.id = id
    self.conversation = conversation
    self.deadline = deadline
    self.openedAt = openedAt
    self.lastParkReminderAt = lastParkReminderAt
    self.parkReminderCount = parkReminderCount
  }
}

// The fold the design note calls "one function over one transcript with two
// outputs, owed conversations and open requests". Nothing else reads it.
public struct SettleState: Hashable, Sendable, Codable {
  public enum Owed: Hashable, Sendable, Codable {
    case owed
    case reminded
  }

  public var owed: [ConversationID: Owed]
  public var openRequests: [RequestID: OpenRequest]
  // A final closes its request for good. Keeping the set makes the fold
  // order-independent for requests, where the tie-break that keeps an owe
  // conservative would otherwise re-open one a same-instant final closed.
  private var closed: Set<RequestID> = []

  public init(owed: [ConversationID: Owed] = [:], openRequests: [RequestID: OpenRequest] = [:]) {
    self.owed = owed
    self.openRequests = openRequests
  }

  public init(folding events: some Sequence<SettleEvent>) {
    self.init()
    for event in events { apply(event) }
  }

  public mutating func apply(_ event: SettleEvent) {
    switch event {
    case let .delivered(delivered):
      if delivered.owesReply { owed[delivered.conversation] = .owed }
      if delivered.kind == .request, let request = delivered.request, !closed.contains(request) {
        openRequests[request] = OpenRequest(
          id: request,
          conversation: delivered.conversation,
          deadline: delivered.deadline,
          openedAt: delivered.at,
        )
      }
    case let .posted(posted):
      owed[posted.conversation] = nil
      if posted.kind == .final, let request = posted.request {
        openRequests[request] = nil
        closed.insert(request)
      }
    case let .owedReminder(conversations, _):
      for conversation in conversations where owed[conversation] == .owed {
        owed[conversation] = .reminded
      }
    case let .parkReminder(request, at):
      guard var open = openRequests[request] else { break }
      open.lastParkReminderAt = at
      open.parkReminderCount += 1
      openRequests[request] = open
    }
  }

  public var owedConversations: [ConversationID] {
    owed.filter { $0.value == .owed }.keys.map(\.self).sorted { $0.rawValue < $1.rawValue }
  }
}

public enum ParkBackoff {
  // 1, 5, 15 minutes, flat after: the nth reminder waits delay(n) past the
  // previous one. The first one goes out the moment the run settles.
  public static let delays: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]

  public static func delay(after reminders: Int) -> Duration {
    guard reminders > 0 else { return .zero }
    return delays[min(reminders, delays.count) - 1]
  }

  public static func nextFire(after request: OpenRequest, now: Date) -> Date? {
    let base = request.lastParkReminderAt ?? now
    let interval = delay(after: request.parkReminderCount).seconds
    let due = max(now, base.addingTimeInterval(interval))
    guard let deadline = request.deadline else { return due }
    return due <= deadline ? due : nil
  }
}

extension Duration {
  var seconds: TimeInterval {
    let (whole, atto) = components
    return TimeInterval(whole) + TimeInterval(atto) / 1e18
  }
}

extension QueueInput {
  public var settleEvent: SettleEvent? {
    switch self {
    case let .message(message):
      .delivered(.init(
        conversation: message.conversationID,
        kind: message.kind,
        request: message.requestID,
        deadline: message.deadline,
        owesReply: message.owesReply,
        at: message.timestamp,
      ))
    case let .notification(notification):
      switch notification.kind {
      case .owedReply:
        .owedReminder(conversations: notification.conversations, at: notification.timestamp)
      case .parkReminder:
        notification.requestID.map { .parkReminder(request: $0, at: notification.timestamp) }
      case .timer, .spaceObservation, .compactRequest, .childFailed, .requestDeadline, .script, .context:
        nil
      }
    }
  }
}

extension [SettleEvent] {
  // Delivery time is when the session SAW the message, so a mid-generation
  // arrival already sorts after the post that preceded it. The same-instant
  // tie therefore resolves the other way: the post clears.
  public mutating func sortByTime() {
    sort { left, right in
      left.at == right.at ? left.tieBreak < right.tieBreak : left.at < right.at
    }
  }
}
