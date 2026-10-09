import Foundation
import JSONValue
import SessionDomain
import enum WuhuAI.Tool
import struct WuhuAI.ToolCall

enum KernelTool: String {
  case bookmark
  case compact
}

// The composition root appends these to the executor roster only for kernel sessions.
public enum KernelToolset {
  public static let compactToolName: String = KernelTool.compact.rawValue

  public static let tools: [Tool] = [
    Tool(
      name: KernelTool.bookmark.rawValue,
      description: "Drop a named marker in the transcript. A later compact call can fold everything before a bookmark while keeping what follows.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "name": .object(["type": .string("string"), "description": .string("Bookmark name to reference from compact.")]),
        ]),
        "required": .array([]),
        "additionalProperties": .bool(false),
      ]),
    ),
    Tool(
      name: KernelTool.compact.rawValue,
      description: "Compact the conversation: everything before the cut is replaced by your summary. Name a bookmark to keep the transcript after it; omit it to fold everything. List files to re-read so the next generation re-establishes its working context.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "summary": .object(["type": .string("string"), "description": .string("Summary that replaces the folded transcript.")]),
          "pre_reads": .object([
            "type": .string("array"),
            "description": .string("Files to re-read at the head of the new generation: /<path> in the space or machines://<name-or-id>/<path>."),
            "items": .object(["type": .string("string")]),
          ]),
          "bookmark": .object(["type": .string("string"), "description": .string("Keep the transcript after this bookmark.")]),
        ]),
        "required": .array([.string("summary")]),
        "additionalProperties": .bool(false),
      ]),
    ),
  ]
}

struct BookmarkArguments: Codable {
  var name: String?
}

struct CompactArguments: Codable {
  var summary: String
  var preReads: [String]?
  var bookmark: String?

  enum CodingKeys: String, CodingKey {
    case summary
    case preReads = "pre_reads"
    case bookmark
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompactArgumentsError.emptySummary }
    preReads = try container.decodeIfPresent([String].self, forKey: .preReads)
    bookmark = try container.decodeIfPresent(String.self, forKey: .bookmark)
  }
}

enum CompactArgumentsError: Error, Equatable, CustomStringConvertible {
  case emptySummary

  var description: String {
    switch self {
    case .emptySummary: "emptySummary: compact requires a non-empty summary"
    }
  }
}

func decodeArguments<T: Decodable>(_ type: T.Type, from call: ToolCall) throws -> T {
  try JSONValueDecoder().decode(type, from: call.arguments.json)
}

struct BookmarkNotFound: Error {
  var name: String
}

extension Transcript {
  func compactCallIndex(_ callID: ToolCallID) -> Int {
    let index = items.firstIndex { item in
      guard case let .assistant(entry) = item else { return false }
      return entry.toolCalls.contains { $0.id == callID.rawValue }
    }
    guard let index else {
      preconditionFailure("compact tool call \(callID.rawValue) is not in the transcript")
    }
    return index
  }

  // Fold everything before the named bookmark; keep from the bookmark's region
  // up to (excluding) the compact call's assistant entry. The marker itself and
  // any tool results right after it are skipped: their paired calls get
  // summarized away and an orphaned tool result is a provider error.
  func compactKeptRange(callID: ToolCallID, bookmark name: String?) throws -> Range<Int>? {
    let end = compactCallIndex(callID)
    guard let name else { return nil }
    let markerIndex = items[..<end].lastIndex { item in
      guard case let .bookmark(marker) = item else { return false }
      return marker.name == name
    }
    guard let markerIndex else { throw BookmarkNotFound(name: name) }
    var start = markerIndex + 1
    while start < end, isPairedToEarlierCall(items[start]) {
      start += 1
    }
    return start < end ? start ..< end : nil
  }
}

private func isPairedToEarlierCall(_ item: TranscriptItem) -> Bool {
  switch item {
  case .toolResult, .bookmark:
    true
  case let .notification(notification):
    notification.kind == .context
  case .direct, .message, .assistant, .generationHead:
    false
  }
}

extension StateSnapshot {
  init(carrying state: ToolExecutionState, arguments: CompactArguments) {
    self.init(subscriptions: state.subscriptions, preReads: arguments.preReads ?? [])
  }
}

extension GenerationHead {
  var reestablishmentCalls: [ToolCall] {
    snapshot.preReads.map { path in
      ToolCall(
        id: "reestablish-\(id.uuidString.lowercased())-read-\(path)",
        name: "read",
        arguments: .object(["path": .string(path)]),
      )
    }
  }
}
