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
  var rendered: String {
    let subs = subscriptions.isEmpty
      ? "none"
      : subscriptions.keys.map(\.rawValue).sorted().joined(separator: ", ")
    let reads = preReads.isEmpty ? "none" : preReads.joined(separator: ", ")
    return """
    <session-state>
    active subscriptions: \(subs)
    files to re-read (re-established below): \(reads)
    </session-state>
    """
  }
}

extension GenerationHead {
  // Role and position are contract: the snapshot is the generation's first
  // user-role message; the summary follows it. A creation head has no summary
  // and gets no nudge.
  func renderMessages(session: SessionID) -> [Message] {
    var messages: [Message] = [.user(.init(content: [.text(snapshot.rendered)]))]
    if let note, !note.isEmpty {
      messages.append(.user(.init(content: [.text(note)])))
    }
    if !summary.isEmpty {
      messages.append(.user(.init(content: [.text("<conversation-summary>\n\(summary)\n</conversation-summary>")])))
      messages.append(.user(.init(content: [.text(SessionPrompt.compactionNudge(session: session))])))
    }
    return messages
  }
}

extension Transcript {
  @concurrent
  public func renderRequest(
    session: SessionID,
    systemPrompt: String,
    tools: [Tool]? = nil,
    budget: ContextBudget,
    thresholds: CompactionThresholds = .init(),
    handles: [String: String] = [:],
    devices: [String: String] = [:],
  ) async -> Context {
    var messages: [Message] = []
    // Dialects that want a turn's tool results back to back get its context
    // notices after the last of them.
    var notices: [Message] = []
    for item in items {
      if !item.holdsNotices {
        messages += notices
        notices = []
      }
      switch item {
      case let .generationHead(head):
        messages.append(contentsOf: head.renderMessages(session: session))
      case let .direct(message):
        messages.append(.user(.init(content: message.content.blocks(header: message.header.attributing(handles, devices: devices)))))
      case let .message(message):
        messages.append(.user(.init(content: message.content.blocks(header: message.header.attributing(handles, devices: devices)))))
      case let .notification(notification) where notification.kind == .context:
        guard !notification.content.text.isEmpty else { continue }
        notices.append(.user(.init(content: notification.content.blocks(header: notification.header))))
      case let .notification(notification):
        messages.append(.user(.init(content: notification.content.blocks(header: notification.header))))
      case let .assistant(entry):
        messages.append(.assistant(.init(content: entry.content)))
      case let .toolResult(result):
        switch result.provenance {
        case let .toolCall(callID):
          messages.append(contentsOf: result.render(for: .toolResult(callID)))
        case .compactionReestablishment:
          messages.append(contentsOf: result.render(for: .autoCalledByCompaction))
        }
      case let .bookmark(marker):
        if let callID = marker.toolCallID {
          messages.append(.toolResult(.init(
            toolCallId: callID.rawValue,
            content: [.text("bookmark recorded" + (marker.name.map { ": \($0)" } ?? ""))],
          )))
        }
      }
    }

    messages += notices

    // Volatile by design: a persisted item with a live percentage is
    // incoherent. Recomputed per render, appended at the tail only.
    let fullness = contextFullness(budget: budget)
    if fullness >= thresholds.soft {
      let percent = Int((fullness * 100).rounded())
      messages.append(.user(.init(content: [.text("""
      <compaction-notice>
      Context is \(percent)% full. Compact at a natural boundary of your choosing: \
      call bookmark to mark a cut point, then compact to fold everything before it.
      </compaction-notice>
      """)])))
    }

    return Context(systemPrompt: systemPrompt, messages: messages, tools: tools)
  }
}

extension TranscriptItem {
  fileprivate var holdsNotices: Bool {
    switch self {
    case .toolResult, .bookmark: true
    case let .notification(notification): notification.kind == .context
    case .direct, .message, .assistant, .generationHead: false
    }
  }
}
