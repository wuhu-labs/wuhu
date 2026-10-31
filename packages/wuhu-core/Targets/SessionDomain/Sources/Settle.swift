import Foundation

public enum SettleEvent: Hashable, Sendable {
  case delivered(Delivered)
  case posted(Posted)
  case owedReminder(conversations: [ConversationID], at: Date)

  public struct Delivered: Hashable, Sendable {
    public var conversation: ConversationID
    // Owed-reply scope, decided by the projection: an agent's own box and its
    // DMs with users, nothing else.
    public var owesReply: Bool
    public var at: Date

    public init(conversation: ConversationID, owesReply: Bool, at: Date) {
      self.conversation = conversation
      self.owesReply = owesReply
      self.at = at
    }
  }

  public struct Posted: Hashable, Sendable {
    public var conversation: ConversationID
    public var at: Date

    public init(conversation: ConversationID, at: Date) {
      self.conversation = conversation
      self.at = at
    }
  }

  var at: Date {
    switch self {
    case let .delivered(event): event.at
    case let .posted(event): event.at
    case let .owedReminder(_, at): at
    }
  }

  var tieBreak: Int {
    switch self {
    case .delivered: 0
    case .posted: 1
    case .owedReminder: 2
    }
  }
}

/// A request whose final report this session owes, as the requests table holds it.
public struct OpenRequest: Hashable, Sendable, Codable {
  public var id: RequestID
  public var deadline: Date?

  public init(id: RequestID, deadline: Date? = nil) {
    self.id = id
    self.deadline = deadline
  }
}

public struct SettleState: Hashable, Sendable, Codable {
  public enum Owed: Hashable, Sendable, Codable {
    case owed
    case reminded
  }

  public var owed: [ConversationID: Owed]

  public init(owed: [ConversationID: Owed] = [:]) {
    self.owed = owed
  }

  public init(folding events: some Sequence<SettleEvent>) {
    self.init()
    for event in events { apply(event) }
  }

  public mutating func apply(_ event: SettleEvent) {
    switch event {
    case let .delivered(delivered):
      if delivered.owesReply { owed[delivered.conversation] = .owed }
    case let .posted(posted):
      owed[posted.conversation] = nil
    case let .owedReminder(conversations, _):
      for conversation in conversations where owed[conversation] == .owed {
        owed[conversation] = .reminded
      }
    }
  }

  public var owedConversations: [ConversationID] {
    owed.filter { $0.value == .owed }.keys.map(\.self).sorted { $0.rawValue < $1.rawValue }
  }
}

struct ParkReminders: Hashable, Sendable, Codable {
  var count: Int
  var last: Date
}

enum ParkBackoff {
  // 1, 5, 15 minutes, flat after: the nth reminder waits delay(n) past the
  // previous one. The first one goes out the moment the run settles.
  static let delays: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]

  static func delay(after reminders: Int) -> Duration {
    guard reminders > 0 else { return .zero }
    return delays[min(reminders, delays.count) - 1]
  }

  static func nextFire(after request: OpenRequest, reminded: ParkReminders?, now: Date) -> Date? {
    let base = reminded?.last ?? now
    let interval = delay(after: reminded?.count ?? 0).seconds
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
      .delivered(.init(conversation: message.conversationID, owesReply: message.owesReply, at: message.timestamp))
    case let .notification(notification):
      switch notification.kind {
      case .owedReply:
        .owedReminder(conversations: notification.conversations, at: notification.timestamp)
      case .timer, .spaceObservation, .compactRequest, .childFailed, .requestDeadline, .requestStall, .script, .exec, .context, .parkReminder:
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
