import Foundation

public enum Subscription: Hashable, Sendable, Codable {
  case observe(sql: String)
  case stream(URL)
  case timer(TimerSchedule)
}

public struct ToolExecutionState: Hashable, Sendable {
  public var fileAccessLog: [String: FileRevision]
  public var folderRoots: [String: String?]
  public var deliveredContext: [String: String]

  public init(
    fileAccessLog: [String: FileRevision] = [:],
    folderRoots: [String: String?] = [:],
    deliveredContext: [String: String] = [:],
  ) {
    self.fileAccessLog = fileAccessLog
    self.folderRoots = folderRoots
    self.deliveredContext = deliveredContext
  }

  public mutating func apply(delivered input: QueueInput) {
    guard case let .notification(notification) = input else { return }
    folderRoots.merge(notification.folderRoots ?? [:]) { $1 }
    deliveredContext.merge(notification.deliveredContext ?? [:]) { first, _ in first }
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
         .manipulateUI, .script, .text, .failure, .sendMessage, .report, .request, .observe, .timer, .cancelObservation, .cancelTimer:
      break
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

  public static func script(_ id: String) -> SubscriptionID {
    SubscriptionID("script.\(id)")
  }

  /// An exec job's handle, `exec.<exec id>`: what its end is announced as and
  /// what cancel takes.
  public static func exec(_ id: String) -> SubscriptionID {
    SubscriptionID("exec.\(id)")
  }
}

public struct StateSnapshot: Hashable, Sendable, Codable {
  /// What the session had armed when its cell wrote the generation.
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
}
