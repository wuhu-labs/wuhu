#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
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
      description: "Compact the conversation: everything before the cut is replaced by your summary. Name a bookmark to keep the transcript after it; omit it to fold everything. List files to re-read so the next generation re-establishes its working context. Name a model to continue on it from the summary: the target is checked first, and a refused one folds nothing. Park when no more work is coming: your turn ends there, and the next generation starts at your next wake, with the prompt and model placement as of then; it is refused while you owe a reply or a request its final report.",
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
          "model": .object(["type": .string("string"), "description": .string("Continue on this target after the compaction: provider/model or a model group id from /model-groups.json. Omit to stay on the current one.")]),
          "effort": .object(["type": .string("string"), "description": .string("Reasoning effort for model; defaults to the current effort when model names the current target, else the target's default.")]),
          "park": .object(["type": .string("boolean"), "description": .string("End the turn and start the next generation at the next wake instead of now. Not with model.")]),
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
  var model: String?
  var effort: String?
  var park: Bool

  enum CodingKeys: String, CodingKey {
    case summary
    case preReads = "pre_reads"
    case bookmark
    case model
    case effort
    case park
  }

  var target: CompactionTarget? { model.map { CompactionTarget(model: $0, effort: effort) } }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompactArgumentsError.emptySummary }
    preReads = try container.decodeIfPresent([String].self, forKey: .preReads)
    bookmark = try container.decodeIfPresent(String.self, forKey: .bookmark)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    if let model, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CompactArgumentsError.emptyModel }
    if effort != nil, model == nil { throw CompactArgumentsError.effortWithoutModel }
    park = try container.decodeIfPresent(Bool.self, forKey: .park) ?? false
    if park, model != nil { throw CompactArgumentsError.parkWithModel }
  }
}

enum CompactArgumentsError: Error, Equatable, CustomStringConvertible {
  case emptySummary
  case emptyModel
  case effortWithoutModel
  case parkWithModel

  var description: String {
    switch self {
    case .emptySummary: "emptySummary: compact requires a non-empty summary"
    case .emptyModel: "emptyModel: model names provider/model or a model group id; omit it to stay on the current target"
    case .effortWithoutModel: "effortWithoutModel: effort applies to a model target; name model too"
    case .parkWithModel: "parkWithModel: a parked compaction is placed at the next wake; omit model, or omit park to switch now"
    }
  }
}

// A parked session runs no nags, so a park that skipped what it owes would
// drop that obligation for good.
enum ParkRefusal: Error, Equatable, CustomStringConvertible {
  case owesReply(conversations: [ConversationID])
  case owesReport(requests: [RequestID])

  init?(_ nags: NagState, task: Bool, openRequests: [OpenRequest]) {
    if !task, case let owed = nags.settle.owedConversations, !owed.isEmpty {
      self = .owesReply(conversations: owed)
    } else if !openRequests.isEmpty {
      self = .owesReport(requests: openRequests.map(\.id).sorted { $0.rawValue < $1.rawValue })
    } else {
      return nil
    }
  }

  var description: String {
    switch self {
    case let .owesReply(conversations): "owesReply: park is refused while you owe a reply in \(conversations.map(\.rawValue).joined(separator: ", ")); reply first, or compact without park"
    case let .owesReport(requests): "owesReport: park is refused while request \(requests.map(\.rawValue).joined(separator: ", ")) waits for your final report; report first, or compact without park"
    }
  }
}

func decodeArguments<T: Decodable>(_ type: T.Type, from call: ToolCall) throws -> T {
  try call.arguments.decode(type)
}

struct BookmarkNotFound: Error {
  var name: String
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
