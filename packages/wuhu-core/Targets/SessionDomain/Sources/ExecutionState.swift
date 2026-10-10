import Foundation

public enum Subscription: Hashable, Sendable, Codable {
  case observe(sql: String)
  case timer(TimerSchedule)
  case requestDeadline(Date)
}

public struct ToolExecutionState: Hashable, Sendable {
  public var fileAccessLog: [String: FileRevision]
  public var folderRoots: [String: String?]
  public var subscriptions: [SubscriptionID: Subscription]

  public init(
    fileAccessLog: [String: FileRevision] = [:],
    folderRoots: [String: String?] = [:],
    subscriptions: [SubscriptionID: Subscription] = [:],
  ) {
    self.fileAccessLog = fileAccessLog
    self.folderRoots = folderRoots
    self.subscriptions = subscriptions
  }

  public init(resuming snapshot: StateSnapshot) {
    self.init(subscriptions: snapshot.subscriptions)
  }

  // A final ends the deadline on its request; it is delivered only after the
  // request's own tool result, so the two never race.
  public mutating func apply(delivered input: QueueInput) {
    switch input {
    case let .notification(notification):
      folderRoots.merge(notification.folderRoots ?? [:]) { $1 }
      if notification.endsSubscription {
        subscriptions.removeValue(forKey: notification.subscriptionID)
      }
    case let .message(message):
      if message.kind == .final, let request = message.requestID {
        subscriptions.removeValue(forKey: .deadline(request))
      }
    }
  }

  public mutating func apply(_ payload: ToolResultPayload) {
    switch payload {
    case let .read(result):
      fileAccessLog[result.path] = result.revision
    case let .write(result):
      fileAccessLog[result.path] = result.revision
    case let .edit(result):
      fileAccessLog[result.path] = result.revision
    case .grep, .find, .exec, .mount, .machines, .templates, .query, .createSession, .setTitle, .compact,
         .manipulateUI, .script, .failure, .sendMessage, .report:
      break
    case let .request(result):
      if let deadline = result.deadline {
        subscriptions[.deadline(result.requestID)] = .requestDeadline(deadline)
      }
    case let .observe(result):
      subscriptions[result.subscriptionID] = .observe(sql: result.sql)
    case let .timer(result):
      subscriptions[result.subscriptionID] = .timer(result.schedule)
    case let .cancelObservation(result):
      subscriptions.removeValue(forKey: result.subscriptionID)
    case let .cancelTimer(result):
      subscriptions.removeValue(forKey: result.subscriptionID)
    }
  }
}

extension SubscriptionID {
  public static let compactRequest: SubscriptionID = SubscriptionID("command.compact")
  public static let owedReply: SubscriptionID = SubscriptionID("owed.reply")
  public static let context: SubscriptionID = SubscriptionID("context")

  public static func park(_ request: RequestID) -> SubscriptionID {
    SubscriptionID("park.\(request.rawValue)")
  }

  public static func deadline(_ request: RequestID) -> SubscriptionID {
    SubscriptionID("deadline.\(request.rawValue)")
  }

  public static func script(_ id: String) -> SubscriptionID {
    SubscriptionID("script.\(id)")
  }
}

// Environments stored before repository context existed carry no folderRoots.
extension ToolExecutionState: Codable {
  enum CodingKeys: String, CodingKey {
    case fileAccessLog
    case folderRoots
    case subscriptions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      fileAccessLog: try container.decode([String: FileRevision].self, forKey: .fileAccessLog),
      folderRoots: try container.decodeIfPresent([String: String?].self, forKey: .folderRoots) ?? [:],
      subscriptions: try container.decode([SubscriptionID: Subscription].self, forKey: .subscriptions),
    )
  }
}

public struct StateSnapshot: Hashable, Sendable, Codable {
  public var subscriptions: [SubscriptionID: Subscription]
  public var preReads: [String]

  public init(
    subscriptions: [SubscriptionID: Subscription] = [:],
    preReads: [String] = [],
  ) {
    self.subscriptions = subscriptions
    self.preReads = preReads
  }

  public var isEmpty: Bool {
    subscriptions.isEmpty && preReads.isEmpty
  }

  public init(carrying state: ToolExecutionState, preReads: [String]) {
    self.init(subscriptions: state.subscriptions, preReads: preReads)
  }
}
