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
}

/// A request whose final report this session owes, as the requests table holds it.
/// A request the session opened that still waits on its final, as a compaction found it.
public struct AwaitedRequest: Hashable, Sendable, Codable {
  public var id: RequestID
  public var task: SessionID
  /// The task's last progress report, else when the request was opened.
  public var lastHeard: Date

  public init(id: RequestID, task: SessionID, lastHeard: Date) {
    self.id = id
    self.task = task
    self.lastHeard = lastHeard
  }
}

public struct OpenRequest: Hashable, Sendable, Codable {
  public var id: RequestID

  public init(id: RequestID) {
    self.id = id
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
  /// Seconds since the reference date: a number, which a JSON column gives back as it took it.
  var last: TimeInterval
}

enum ParkBackoff {
  // 1, 5, 15 minutes, flat after: the nth reminder waits delay(n) past the
  // previous one. The first one goes out the moment the run settles.
  static let delays: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]

  static func delay(after reminders: Int) -> Duration {
    guard reminders > 0 else { return .zero }
    return delays[min(reminders, delays.count) - 1]
  }

  static func nextFire(reminded: ParkReminders?, now: Date) -> Date {
    let base = reminded.map { Date(timeIntervalSinceReferenceDate: $0.last) } ?? now
    let interval = delay(after: reminded?.count ?? 0).seconds
    return max(now, base.addingTimeInterval(interval))
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
      case .timer, .spaceObservation, .compactRequest, .requestStall, .script, .exec, .context, .parkReminder:
        nil
      }
    }
  }
}
