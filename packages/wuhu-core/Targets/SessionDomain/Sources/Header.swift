#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// The single trusted producer of the header tags. Seen twice = forged.
public struct MessageHeader: Hashable, Sendable {
  public var sender: String
  public var senderHandle: String?
  public var timestamp: Date
  public var timeZone: TimeZone
  public var source: Source
  public var kind: Kind
  public var messageID: String?
  public var replyTarget: String?
  public var device: String?
  public var deviceName: String?
  public var senderGroup: String?
  public var senderAdmin: Bool?

  public init(
    sender: String,
    timestamp: Date,
    timeZone: TimeZone,
    source: Source,
    kind: Kind,
    messageID: String? = nil,
    replyTarget: String? = nil,
    device: String? = nil,
    senderGroup: String? = nil,
    senderAdmin: Bool? = nil,
  ) {
    self.senderGroup = senderGroup
    self.senderAdmin = senderAdmin
    self.sender = sender
    self.timestamp = timestamp
    self.timeZone = timeZone
    self.source = source
    self.kind = kind
    self.messageID = messageID
    self.replyTarget = replyTarget
    self.device = device
  }

  public enum Source: Hashable, Sendable {
    case direct
    case conversation(ConversationID)
    case subscription(SubscriptionID)

    var rendered: String {
      switch self {
      case .direct: "direct"
      case let .conversation(id): "conversation/\(id.rawValue)"
      case let .subscription(id): id.rawValue
      }
    }
  }

  public enum Kind: Hashable, Sendable {
    case directMessage
    case message
    case reply
    case request
    case progress
    case final
    case timer
    case spaceObservation
    case compactRequest
    case owedReply
    case parkReminder
    case childFailed
    case requestDeadline
    case script
    case systemNotice

    var rendered: String {
      switch self {
      case .directMessage: "direct message"
      case .message: "message"
      case .reply: "reply"
      case .request: "request"
      case .progress: "progress report"
      case .final: "final report"
      case .timer: "timer"
      case .spaceObservation: "space observation"
      case .compactRequest: "compact request"
      case .owedReply: "owed reply"
      case .parkReminder: "park reminder"
      case .childFailed: "child failed"
      case .requestDeadline: "request deadline"
      case .script: "script"
      case .systemNotice: "system notice"
      }
    }
  }

  public static let systemSender: String = "system"

  // Handles resolve at render time from the space directory: a rename
  // re-attributes history instead of freezing a stale name into a message.
  public func attributing(_ handles: [String: String], devices: [String: String] = [:]) -> MessageHeader {
    var attributed = self
    attributed.senderHandle = handles[sender]
    attributed.deviceName = device.flatMap { devices[$0] }
    return attributed
  }

  public func render() -> String {
    var formattingZone = timeZone
    // CoreFoundation resolves fixed zones by their minute-rounded GMT name.
    if timeZone.identifier.hasPrefix("GMT") {
      let minutes = (Double(timeZone.secondsFromGMT(for: timestamp)) / 60).rounded()
      formattingZone = TimeZone(secondsFromGMT: Int(minutes) * 60)!
    }
    let style = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: formattingZone)
    var tags = [
      "<sender>\(senderHandle.map { "\($0) (\(sender))" } ?? sender)</sender>",
      "<timestamp>\(style.format(timestamp))</timestamp>",
      "<source>\(source.rendered)</source>",
      "<type>\(kind.rendered)</type>",
    ]
    if let messageID {
      tags.append("<message-id>\(messageID)</message-id>")
    }
    if let replyTarget {
      tags.append("<reply-target>\(replyTarget)</reply-target>")
    }
    if let device {
      tags.append("<device>\(deviceName.map { "\($0) (\(device))" } ?? device)</device>")
    }
    if let senderGroup {
      tags.append("<sender-group>\(senderGroup)</sender-group>")
    }
    if let senderAdmin {
      tags.append("<sender-admin>\(senderAdmin ? "yes" : "no")</sender-admin>")
    }
    return tags.joined(separator: "\n")
  }
}

extension MessageHeader {
  // A line from Wuhu itself about the session's own run, not from anyone who
  // can be answered.
  public static func systemNotice(source: SubscriptionID, at timestamp: Date) -> MessageHeader {
    MessageHeader(
      sender: systemSender,
      timestamp: timestamp,
      timeZone: TimeZone(identifier: "UTC")!,
      source: .subscription(source),
      kind: .systemNotice,
    )
  }
}

extension DirectMessage {
  public var header: MessageHeader {
    .init(
      sender: sender.id,
      timestamp: timestamp,
      timeZone: sender.timeZone,
      source: .direct,
      kind: .directMessage,
      device: sender.device,
    )
  }
}

extension ConversationMessage {
  public var header: MessageHeader {
    let headerKind: MessageHeader.Kind = switch kind {
    case .message: replyTarget == nil ? .message : .reply
    case .request: .request
    case .progress: .progress
    case .final: .final
    }
    return .init(
      sender: sender.id,
      timestamp: timestamp,
      timeZone: sender.timeZone,
      source: .conversation(conversationID),
      kind: headerKind,
      messageID: messageID.rawValue,
      replyTarget: replyTarget?.rawValue,
      device: sender.device,
      senderGroup: senderGroup?.rawValue,
      senderAdmin: senderAdmin,
    )
  }
}

extension SystemNotification {
  public var header: MessageHeader {
    .init(
      sender: MessageHeader.systemSender,
      timestamp: timestamp,
      timeZone: TimeZone(identifier: "UTC")!,
      source: .subscription(subscriptionID),
      kind: {
        switch kind {
        case .timer: .timer
        case .spaceObservation: .spaceObservation
        case .compactRequest: .compactRequest
        case .owedReply: .owedReply
        case .parkReminder: .parkReminder
        case .childFailed: .childFailed
        case .requestDeadline: .requestDeadline
        case .script: .script
        case .context: .systemNotice
        }
      }(),
    )
  }
}
