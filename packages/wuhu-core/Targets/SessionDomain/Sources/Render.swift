import Foundation
import WuhuAI

public enum RenderContext: Hashable, Sendable {
  case toolResult(ToolCallID)
  case autoCalledByCompaction
}

extension MessageContent {
  // The paths ride in the text too, so a text-only projection still tells the
  // agent the files exist and where to re-read them. What the model cannot
  // take as an image is only this line.
  var renderedText: String {
    guard !attachments.isEmpty else { return text }
    let lines = attachments.map { attachment in
      guard !attachment.isModelImage, let size = attachment.size else {
        return "\(attachment.path) (\(attachment.mimeType))"
      }
      return "\(attachment.path) (\(attachment.mimeType), \(size) bytes)"
    }
    return text + "\n\n<attachments>\n" + lines.joined(separator: "\n") + "\n</attachments>"
  }

  func blocks(header: MessageHeader) -> [ContentBlock] {
    var blocks: [ContentBlock] = [.text(header.render() + "\n\n" + renderedText)]
    for image in modelImages {
      blocks.append(.media(.init(url: MediaReference.spaceFile(image.path).url, mimeType: image.mimeType)))
    }
    return blocks
  }
}

extension QueueInput {
  public var content: MessageContent {
    switch self {
    case let .message(message): message.content
    case let .notification(notification): notification.content
    }
  }

  // The text a kernel session is shown for this input, header tags included.
  public func rendered(handles: [String: String], devices: [String: String]) -> String {
    let header = switch self {
    case let .message(message): message.header.attributing(handles, devices: devices)
    case let .notification(notification): notification.header
    }
    return header.render() + "\n\n" + content.renderedText
  }
}

extension ImageContent {
  var block: ContentBlock {
    switch source {
    case let .inline(data): .inlineImage(data, mimeType: mimeType)
    case let .blob(hash): .media(.init(url: MediaReference.blob(hash).url, mimeType: mimeType))
    }
  }
}

extension ToolResultItem {
  // Providers reject media inside tool results (Responses folds them to a
  // string), so an image read renders as its text result plus a user-role
  // media message right after.
  public func render(for context: RenderContext) -> [Message] {
    let result: Message = switch context {
    case let .toolResult(callID):
      .toolResult(.init(
        toolCallId: callID.rawValue,
        content: [.text(payload.renderedText)],
        isError: payload.isFailure,
      ))
    case .autoCalledByCompaction:
      .user(.init(content: [.text(reestablishedText)]))
    }
    guard case let .read(read) = payload, let image = read.image else { return [result] }
    return [result, .user(.init(content: [
      .text("image read from \(read.path):"),
      image.block,
    ]))]
  }

  private var reestablishedText: String {
    let subject = if case let .read(result) = payload { " \(result.path)" } else { "" }
    return "<compaction-reestablished\(subject)>\n"
      + payload.renderedText
      + "\n</compaction-reestablished>"
  }
}

extension StateSnapshot {
  func rendered(running: [String], awaiting: [AwaitedRequest] = []) -> String {
    let subs = subscriptions.isEmpty
      ? "none"
      : subscriptions.keys.map(\.rawValue).sorted().joined(separator: ", ")
    let reads = preReads.isEmpty ? "none" : preReads.joined(separator: ", ")
    let work = running.isEmpty ? "none" : running.sorted().joined(separator: ", ")
    let awaited = awaiting.isEmpty ? "" : "\nawaiting final reports: " + awaiting.map { request in
      "\(request.id.rawValue) from \(request.task.rawValue) (last heard \(request.lastHeard.formatted(.iso8601)))"
    }.joined(separator: ", ")
    return """
    <session-state>
    active subscriptions: \(subs)
    running: \(work)\(awaited)
    files to re-read (re-established below): \(reads)
    </session-state>
    """
  }
}

extension GenerationHead {
  // Role and position are contract: the snapshot is the generation's first
  // user-role message; the summary follows it. A creation head has no summary
  // and gets no nudge.
  func renderLines(session: SessionID) -> [TranscriptLine] {
    func line(_ key: String, _ text: String) -> TranscriptLine {
      TranscriptLine(at: timestamp, key: key, message: .user(.init(content: [.text(text)])))
    }
    var lines = [line("head", snapshot.rendered(running: runningWork ?? [], awaiting: awaiting ?? []))]
    if let note, !note.isEmpty {
      lines.append(line("head:note", note))
    }
    if !summary.isEmpty {
      lines.append(line("head:summary", "<conversation-summary>\n\(summary)\n</conversation-summary>"))
      lines.append(line("head:nudge", SessionPrompt.compactionNudge(session: session)))
    }
    return lines
  }
}

extension Transcript {
  @concurrent
  public func renderRequest(
    session: SessionID,
    systemPrompt: String,
    tools: [Tool]? = nil,
  ) async -> Context {
    Context(systemPrompt: systemPrompt, messages: Self.lines(session: session, items: items).lines.map(\.message), tools: tools)
  }
}
