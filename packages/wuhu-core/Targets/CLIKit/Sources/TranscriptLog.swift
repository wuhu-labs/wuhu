#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import SpaceContract
import enum WuhuAI.ContentBlock
import struct WuhuAI.ToolCall
import struct WuhuAI.Usage

func renderSessionLog(_ output: SessionLogOutput, level: Int) throws -> String {
  var blocks: [String] = []
  for item in output.items {
    if let block = try renderedKernelItem(item, level: level, clip: clipLimit) {
      blocks.append(block)
    }
  }
  guard !blocks.isEmpty else { return "" }
  return blocks.joined(separator: "\n\n") + "\n"
}

func renderSessionEntry(_ output: SessionEntryOutput) throws -> String {
  guard let block = try renderedKernelItem(output.item, level: 3, clip: nil) else { return "" }
  return block + "\n"
}

func renderConversationLog(_ messages: [ConversationMessagePayload]) -> String {
  var blocks: [String] = []
  for message in messages {
    var head = "[\(message.n)] \(message.senderHandle.map { "\($0) (\(message.sender))" } ?? message.sender)"
    if let kind = message.senderKind {
      head += " · \(kind.rawValue)"
    }
    if let group = message.senderGroup {
      head += " · group \(group)"
    }
    head += " · \(iso(message.createdAt, timezone: message.senderTimezone)) · \(message.kind.rawValue)"
    head += " · id \(message.messageId)"
    if let replyTarget = message.replyTarget {
      head += " · → \(replyTarget)"
    }
    let attached = (message.attachments ?? []).map { "\nattached: \($0.path)" }.joined()
    blocks.append(head + "\n" + message.text + attached)
  }
  guard !blocks.isEmpty else { return "" }
  return blocks.joined(separator: "\n\n") + "\n"
}

private let clipLimit = 4000

private func renderedKernelItem(_ logItem: SessionLogItem, level: Int, clip: Int?) throws -> String? {
  let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(logItem.item.jsonString().utf8))
  let ref = logItem.ref
  switch item {
  case let .direct(message):
    return "[\(ref)] direct · \(message.header.line)\n"
      + clipped(message.content.text, to: clip) + attachmentLines(message.content)
  case let .message(message):
    return "[\(ref)] conversation(\(message.conversationID.rawValue)) · \(message.header.line)\n"
      + clipped(message.content.text, to: clip) + attachmentLines(message.content)
  case let .notification(notification):
    let kind = switch notification.kind {
    case .timer: "timer"
    case .spaceObservation: "space observation"
    case .compactRequest: "compact request"
    case .owedReply: "owed reply"
    case .parkReminder: "park reminder"
    case .childFailed: "child failed"
    case .requestDeadline: "request deadline"
    case .script: "script"
    case .context: "context"
    }
    return "[\(ref)] \(kind) · \(notification.header.line)\n" + clipped(notification.content.text, to: clip)
  case let .assistant(entry):
    var head = "[\(ref)] assistant · \(iso(entry.timestamp))"
    if level >= 2 {
      head += " · \(contextLabel(entry.usage))"
    }
    var lines: [String] = []
    for block in entry.content {
      switch block {
      case let .text(text):
        lines.append(clipped(text.text, to: clip))
      case let .reasoning(reasoning):
        guard level >= 2 else { continue }
        switch reasoning {
        case let .unencrypted(text):
          lines.append("~ " + clipped(text, to: clip))
        case let .encrypted(content):
          lines.append("~ " + clipped(content.summary ?? "(redacted reasoning)", to: clip))
        }
      case let .toolCall(call):
        if level < 2, let reply = narrativeReplyText(call) {
          lines.append("↩ " + clipped(reply, to: clip))
        }
        guard level >= 2 else { continue }
        lines.append("→ \(call.name) " + clipped(call.arguments.text, to: clip))
      case let .hostedTool(item):
        lines.append("→ \(item.digest)")
      case .media:
        lines.append("(media)")
      }
    }
    return ([head] + lines).joined(separator: "\n")
  case let .toolResult(result):
    return "[\(ref)] tool result · \(iso(result.timestamp))\n← " + clipped(result.payload.renderedText, to: clip)
  case let .bookmark(marker):
    return "[\(ref)] bookmark · \(iso(marker.timestamp))\n\(marker.name ?? "(unnamed)")"
  case let .generationHead(head):
    let kind = head.summary.isEmpty ? "generation start" : "compaction"
    let body = head.summary.isEmpty ? (head.note ?? "") : head.summary
    return "[\(ref)] \(kind) · \(iso(head.timestamp))\n" + clipped(body, to: clip)
  }
}

// The reply a session posts travels as tool-call arguments, so the L1
// narrative would otherwise never show what was actually said.
private func narrativeReplyText(_ call: ToolCall) -> String? {
  switch call.name {
  case "send_message": call.arguments.json.object?["message"]?.stringValue
  case "report": call.arguments.json.object?["content"]?.stringValue
  default: nil
  }
}

private func contextLabel(_ usage: Usage) -> String {
  let tokens = usage.totalTokens
  let count = tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
  return "ctx \(count) tok"
}

extension MessageHeader {
  fileprivate var line: String {
    "\(sender) · \(isoFormatted(timestamp, in: timeZone))"
  }
}

private func iso(_ timestamp: Date) -> String {
  isoFormatted(timestamp, in: TimeZone(identifier: "UTC")!)
}

private func iso(_ epoch: Double, timezone: String) -> String {
  isoFormatted(
    Date(timeIntervalSince1970: epoch),
    in: TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!,
  )
}

func isoFormatted(_ timestamp: Date, in timeZone: TimeZone) -> String {
  var formattingZone = timeZone
  // CoreFoundation resolves fixed zones by their minute-rounded GMT name.
  if timeZone.identifier.hasPrefix("GMT") {
    let minutes = (Double(timeZone.secondsFromGMT(for: timestamp)) / 60).rounded()
    formattingZone = TimeZone(secondsFromGMT: Int(minutes) * 60)!
  }
  return Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: formattingZone).format(timestamp)
}

private func attachmentLines(_ content: MessageContent) -> String {
  guard !content.attachments.isEmpty else { return "" }
  return "\n" + content.attachments.map { attachment in
    switch attachment {
    case let .image(path, mimeType, _, _): "attached image: \(path) (\(mimeType))"
    case let .file(path, mimeType, size): "attached file: \(path) (\(mimeType), \(size) bytes)"
    }
  }.joined(separator: "\n")
}

private func clipped(_ text: String, to limit: Int?) -> String {
  guard let limit, text.count > limit else { return text }
  return String(text.prefix(limit)) + "\n…(truncated; wuhu session entry fetches it in full)"
}
