#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import WuhuAI

/// One message of a request as sent, with what produced it beside it.
public struct TranscriptLine: Hashable, Sendable, Codable {
  public enum Role: String, Hashable, Sendable, Codable {
    case system
    case user
    case assistant
    case toolResult = "tool_result"
  }

  /// What a reply's line keeps of its inference. Only a reply made in the generation has one: a line a new generation carries was said in another context.
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

  /// The line as a new generation carries it. `portable` leaves out what only the account that made it can replay; nil when nothing is left.
  public func carried(portable: Bool) -> TranscriptLine? {
    var line = self
    line.meta = nil
    guard portable else { return line }
    line.message = message.portable
    if case let .assistant(reply) = line.message, reply.content.isEmpty { return nil }
    return line
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

public enum LineKey {
  public static let head = "head"
  public static let pressure = "subscription:context-pressure"
  /// A notice of the instructions a tool call's scope brought, which waits behind the turn's last answer.
  public static let scope = "subscription:\(SubscriptionID.context.rawValue)"
  public static let cacheWarming = "subscription:cache-warming"
  public static let toolRoster = "subscription:tool-roster"
}

extension TranscriptItem {
  /// The item's messages as a request sends them, rendered once: the lines are what is stored. A context notice without text is none.
  public func lines(session: SessionID) -> [TranscriptLine] {
    switch self {
    case let .generationHead(head):
      return head.lines(session: session)
    case let .message(message):
      return [.init(at: message.timestamp, key: "message:\(message.messageID.rawValue)", message: .user(.init(content: message.content.blocks(header: message.header))))]
    case let .notification(notification):
      if notification.kind == .context, notification.content.text.isEmpty { return [] }
      return [.init(at: notification.timestamp, key: "subscription:\(notification.subscriptionID.rawValue)", message: .user(.init(content: notification.content.blocks(header: notification.header))))]
    case let .assistant(entry):
      return [.init(
        at: entry.timestamp, key: "attempt:\(entry.id.uuidString.lowercased())", message: .assistant(.init(content: entry.content)),
        meta: .init(stopReason: entry.stopReason, usage: entry.usage),
      )]
    case let .toolResult(result):
      let (context, key) = switch result.provenance {
      case let .toolCall(callID): (RenderContext.toolResult(callID), "call:\(callID.rawValue)")
      case .compactionReestablishment: (RenderContext.autoCalledByCompaction, "reestablish")
      }
      return result.render(for: context).enumerated().map { index, message in
        .init(at: result.timestamp, key: index == 0 ? key : "\(key):image", message: message)
      }
    case let .bookmark(marker):
      return [.init(at: marker.timestamp, key: "call:\(marker.toolCallID.rawValue)", message: .toolResult(.init(
        toolCallId: marker.toolCallID.rawValue,
        content: [.text("bookmark recorded" + (marker.name.map { ": \($0)" } ?? ""))],
      )))]
    }
  }
}

extension [TranscriptLine] {
  /// The call a reply of these lines made.
  public func toolCall(_ id: ToolCallID) -> (index: Int, call: ToolCall)? {
    for (index, line) in enumerated() {
      guard case let .assistant(reply) = line.message else { continue }
      for case let .toolCall(call) in reply.content where call.id == id.rawValue { return (index, call) }
    }
    return nil
  }

  /// A pressure notice the model has not answered yet.
  public var hasPendingPressureNotice: Bool {
    for line in reversed() {
      if line.role == .assistant || line.key == LineKey.head { return false }
      if line.key == LineKey.pressure { return true }
    }
    return false
  }

  /// What a fold keeps: from after the line at `bookmark` up to the reply that made the compact call at `end`. The answers and notices right after the bookmark are left out: their calls are folded away, and an answer without its call is a provider error.
  public func keptRange(after bookmark: Int, upTo end: Int) -> Range<Int>? {
    var start = bookmark + 1
    while start < end, self[start].role == .toolResult || self[start].key.hasSuffix(":image") || self[start].key == LineKey.scope { start += 1 }
    return start < end ? start ..< end : nil
  }
}
