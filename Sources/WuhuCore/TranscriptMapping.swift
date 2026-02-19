import Foundation
import WuhuAPI

func wuhuToTranscriptItem(_ entry: WuhuSessionEntry) -> TranscriptItem {
  let id = TranscriptEntryID(rawValue: "\(entry.id)")
  let createdAt = entry.createdAt

  func textFromBlocks(_ blocks: [WuhuContentBlock]) -> String {
    blocks.compactMap { block in
      if case let .text(text, _) = block { return text }
      return nil
    }.joined(separator: "\n")
  }

  switch entry.payload {
  case let .message(m):
    switch m {
    case let .user(u):
      let author: Author = {
        let trimmed = u.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == WuhuUserMessage.unknownUser { return .unknown }
        return .participant(.init(rawValue: trimmed), kind: .human)
      }()
      return .init(
        id: id,
        createdAt: createdAt,
        entry: .message(.init(author: author, content: .text(textFromBlocks(u.content)))),
      )
    case let .assistant(a):
      return .init(
        id: id,
        createdAt: createdAt,
        entry: .message(.init(author: .participant(.init(rawValue: "agent"), kind: .bot), content: .text(textFromBlocks(a.content)))),
      )
    case let .customMessage(c):
      return .init(
        id: id,
        createdAt: createdAt,
        entry: .message(.init(author: .system, content: .text(textFromBlocks(c.content)))),
      )
    case let .toolResult(t):
      return .init(
        id: id,
        createdAt: createdAt,
        entry: .tool(.init(name: t.toolName, detail: textFromBlocks(t.content))),
      )
    case .unknown:
      return .init(
        id: id,
        createdAt: createdAt,
        entry: .diagnostic(.init(message: "unknown message")),
      )
    }

  case let .toolExecution(t):
    return .init(id: id, createdAt: createdAt, entry: .tool(.init(name: t.toolName, detail: t.phase.rawValue)))

  case .compaction:
    // TODO: represent compaction boundaries explicitly.
    return .init(id: id, createdAt: createdAt, entry: .marker(.executionResumed(trigger: .system)))

  case .sessionSettings:
    return .init(id: id, createdAt: createdAt, entry: .marker(.executionResumed(trigger: .system)))

  case .header:
    return .init(id: id, createdAt: createdAt, entry: .marker(.participantJoined(.system)))

  case let .custom(customType, _):
    return .init(id: id, createdAt: createdAt, entry: .diagnostic(.init(message: "custom: \(customType)")))

  case .unknown:
    return .init(id: id, createdAt: createdAt, entry: .diagnostic(.init(message: "unknown payload")))
  }
}
