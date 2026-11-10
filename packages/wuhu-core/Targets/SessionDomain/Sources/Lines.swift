#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import WuhuAI

/// One message of a request as sent, with what produced it beside it.
public struct TranscriptLine: Hashable, Sendable {
  public enum Role: String, Hashable, Sendable, Codable {
    case system
    case user
    case assistant
    case toolResult = "tool_result"
  }

  public struct Meta: Hashable, Sendable, Codable {
    public var stopReason: StopReason
    public var usage: Usage

    public init(stopReason: StopReason, usage: Usage) {
      self.stopReason = stopReason
      self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
      case stopReason = "stop_reason"
      case usage
    }
  }

  public var at: Date
  public var key: String
  public var message: Message
  public var meta: Meta?

  public init(at: Date, key: String, message: Message, meta: Meta? = nil) {
    self.at = at
    self.key = key
    self.message = message
    self.meta = meta
  }

  public var role: Role {
    switch message {
    case .user: .user
    case .assistant: .assistant
    case .toolResult: .toolResult
    }
  }
}

/// Position 0 of a generation: what a request sends besides its messages.
public struct TranscriptPreamble: Hashable, Sendable, Codable {
  public var system: String
  public var tools: [Tool]

  public init(system: String, tools: [Tool]) {
    self.system = system
    self.tools = tools
  }
}

extension Transcript {
  /// The request's messages as lines. Lines past `settled` are context notices
  /// still held behind a turn's tool results: the next item may land before them.
  public static func lines(session: SessionID, items: some Sequence<TranscriptItem>) -> (lines: [TranscriptLine], settled: Int) {
    var lines: [TranscriptLine] = []
    // Dialects that want a turn's tool results back to back get its context
    // notices after the last of them.
    var held: [TranscriptLine] = []
    for item in items {
      if !item.holdsNotices {
        lines += held
        held = []
      }
      switch item {
      case let .generationHead(head):
        lines += head.renderLines(session: session)
      case let .direct(message):
        lines.append(.init(at: message.timestamp, key: "direct:\(message.id.uuidString.lowercased())", message: .user(.init(content: message.content.blocks(header: message.header)))))
      case let .message(message):
        lines.append(.init(at: message.timestamp, key: "message:\(message.messageID.rawValue)", message: .user(.init(content: message.content.blocks(header: message.header)))))
      case let .notification(notification) where notification.kind == .context:
        guard !notification.content.text.isEmpty else { continue }
        held.append(notification.line)
      case let .notification(notification):
        lines.append(notification.line)
      case let .assistant(entry):
        lines.append(.init(
          at: entry.timestamp, key: "attempt:\(entry.id.uuidString.lowercased())", message: .assistant(.init(content: entry.content)),
          meta: .init(stopReason: entry.stopReason, usage: entry.usage),
        ))
      case let .toolResult(result):
        let (context, key) = switch result.provenance {
        case let .toolCall(callID): (RenderContext.toolResult(callID), "call:\(callID.rawValue)")
        case .compactionReestablishment: (RenderContext.autoCalledByCompaction, "reestablish")
        }
        for (index, message) in result.render(for: context).enumerated() {
          lines.append(.init(at: result.timestamp, key: index == 0 ? key : "\(key):image", message: message))
        }
      case let .bookmark(marker):
        if let callID = marker.toolCallID {
          lines.append(.init(at: marker.timestamp, key: "call:\(callID.rawValue)", message: .toolResult(.init(
            toolCallId: callID.rawValue,
            content: [.text("bookmark recorded" + (marker.name.map { ": \($0)" } ?? ""))],
          ))))
        }
      }
    }
    return (lines + held, lines.count)
  }
}

extension SystemNotification {
  fileprivate var line: TranscriptLine {
    .init(at: timestamp, key: "subscription:\(subscriptionID.rawValue)", message: .user(.init(content: content.blocks(header: header))))
  }
}

extension TranscriptItem {
  /// Whether a context notice before this item stays held behind it.
  public var holdsNotices: Bool {
    switch self {
    case .toolResult, .bookmark: true
    case let .notification(notification): notification.kind == .context
    case .direct, .message, .assistant, .generationHead: false
    }
  }
}
