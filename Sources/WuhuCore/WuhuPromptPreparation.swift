import Foundation
import PiAI
import WuhuAPI

enum WuhuPromptPreparation {
  static func extractHeader(from transcript: [WuhuSessionEntry], sessionID: String) throws -> WuhuSessionHeader {
    guard let headerEntry = transcript.first(where: { $0.parentEntryID == nil }) else {
      throw WuhuStoreError.noHeaderEntry(sessionID)
    }
    guard case let .header(header) = headerEntry.payload else {
      throw WuhuStoreError.sessionCorrupt("Header entry \(headerEntry.id) payload is not header")
    }
    return header
  }

  static func extractReasoningEffort(from header: WuhuSessionHeader) -> ReasoningEffort? {
    guard let metadata = header.metadata.object else { return nil }
    guard let raw = metadata["reasoningEffort"]?.stringValue else { return nil }
    return ReasoningEffort(rawValue: raw)
  }

  static func extractContextMessages(from transcript: [WuhuSessionEntry]) -> [Message] {
    let headerIndex = transcript.firstIndex(where: { $0.parentEntryID == nil }) ?? 0
    let reminderIndex = WuhuGroupChat.reminderEntryIndex(in: transcript)

    var summary: String?
    var firstKeptEntryID: Int64?

    if let entry = transcript.last(where: { if case .compaction = $0.payload { return true }; return false }),
       case let .compaction(compaction) = entry.payload
    {
      summary = compaction.summary
      firstKeptEntryID = compaction.firstKeptEntryID
    }

    let startIndex: Int = if let firstKeptEntryID {
      transcript.firstIndex(where: { $0.id == firstKeptEntryID }) ?? min(headerIndex + 1, transcript.count)
    } else {
      min(headerIndex + 1, transcript.count)
    }

    var messages: [Message] = []
    if let summary, !summary.isEmpty {
      messages.append(WuhuCompactionEngine.makeSummaryMessage(summary: summary))
    }

    for (idx, entry) in transcript[startIndex...].enumerated() {
      let entryIndex = startIndex + idx
      guard case let .message(m) = entry.payload else { continue }
      guard let pi = WuhuGroupChat.renderForLLM(message: m, entryIndex: entryIndex, reminderIndex: reminderIndex) else { continue }
      messages.append(pi)
    }

    return WuhuToolRepairer.repairMissingToolResultsInMemory(messages)
  }

  static func extractLatestSessionSettings(from transcript: [WuhuSessionEntry]) -> WuhuSessionSettings? {
    for entry in transcript.reversed() {
      if case let .sessionSettings(s) = entry.payload {
        return s
      }
    }
    return nil
  }

  static func normalizeUser(_ user: String?) -> String {
    let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? WuhuUserMessage.unknownUser : trimmed
  }

  static func firstPromptingUser(in transcript: [WuhuSessionEntry]) -> String? {
    for entry in transcript {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .user(u) = m else { continue }
      return u.user
    }
    return nil
  }
}

