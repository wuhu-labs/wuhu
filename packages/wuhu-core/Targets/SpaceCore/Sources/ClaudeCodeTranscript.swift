#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONValue
import OrderedCollections
import SessionDomain
import StructuredQueries
import enum WuhuAI.ContentBlock
import enum WuhuAI.StopReason
import struct WuhuAI.TextContent
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall
import struct WuhuAI.Usage

typealias ClaudeCodeEntry = OrderedDictionary<String, JSONValue>

// What the transcript joins onto the lines it translates, each keyed the way a
// line names it.
struct ClaudeCodeJoins {
  var receipts: [String: ToolResultPayload] = [:]
  var handovers: [String: [(effect: ClaudeCodeHandoverEffect, at: Date)]] = [:]
  var queued: [Int: QueueInput] = [:]
}

// Claude Code's stored log of one generation, read as the kernel's transcript.
// Items are final once their line is stored: a receipt lands before the tool
// result that names it, and a handover is recorded with its confirming line.
struct ClaudeCodeTranscript: Hashable, Sendable {
  let generation: Int64
  private(set) var nextLine = 0
  private(set) var count = 0
  private var seen: Set<String> = []
  private var wuhuCalls: Set<String> = []

  init(generation: Int64, wuhuCalls: Set<String> = []) {
    self.generation = generation
    self.wuhuCalls = wuhuCalls
  }

  // `lines` continues the generation at `nextLine`. A generation a compaction
  // opened starts with the lines it carried, then its boundary, then the
  // summary; the summary's head goes first, as a kernel head does.
  mutating func advance(_ lines: [ClaudeCodeEntry], kept: Int, joins: ClaudeCodeJoins) -> [TranscriptItem] {
    var order = Array(lines.indices)
    if nextLine == 0, kept > 0 {
      guard lines.count > kept else { return [] }
      if lines[kept]["isCompactSummary"]?.boolValue == true {
        order = [kept] + Array(0 ..< kept) + Array(kept + 1 ..< lines.count)
      }
    }
    nextLine += lines.count
    var items: [TranscriptItem] = []
    for index in order {
      items += translate(lines[index], joins: joins)
    }
    count += items.count
    return items
  }

  mutating func translate(_ entry: ClaudeCodeEntry, joins: ClaudeCodeJoins) -> [TranscriptItem] {
    guard let uuid = entry["uuid"]?.stringValue, seen.insert(uuid).inserted else { return [] }
    let at = entry["timestamp"]?.stringValue.flatMap(claudeCodeTimestamp) ?? .distantPast
    switch entry["type"]?.stringValue {
    case "assistant":
      return assistant(entry, uuid: uuid, at: at)
    case "user":
      return user(entry, uuid: uuid, at: at, joins: joins)
    case "attachment":
      guard let attachment = entry["attachment"]?.object, attachment["type"] == "hook_additional_context" else { return [] }
      return handover(uuid, at: at, pieces: attachment["content"]?.array?.compactMap(\.stringValue) ?? [], joins: joins)
    default:
      return []
    }
  }

  mutating func assistant(_ entry: ClaudeCodeEntry, uuid: String, at: Date) -> [TranscriptItem] {
    guard let message = entry["message"]?.object else { return [] }
    var content: [ContentBlock] = []
    for block in message["content"]?.array ?? [] {
      guard let fields = block.object else { continue }
      switch fields["type"]?.stringValue {
      case "text":
        if let text = fields["text"]?.stringValue { content.append(.text(TextContent(text: text))) }
      case "thinking":
        if let thinking = fields["thinking"]?.stringValue, !thinking.isEmpty { content.append(.reasoning(.unencrypted(thinking))) }
      case "tool_use":
        guard let id = fields["id"]?.stringValue, let name = fields["name"]?.stringValue else { continue }
        let wuhu = name.hasPrefix(Self.wuhuPrefix)
        if wuhu { wuhuCalls.insert(id) }
        content.append(.toolCall(ToolCall(
          id: id,
          name: wuhu ? String(name.dropFirst(Self.wuhuPrefix.count)) : Self.builtinNames[name] ?? name,
          arguments: ToolArguments(fields["input"] ?? .object([:])),
        )))
      default:
        continue
      }
    }
    guard !content.isEmpty else { return [] }
    let usage = message["usage"]?.object
    func tokens(_ key: String) -> Int { usage?[key]?.intValue ?? 0 }
    let cacheWrite = tokens("cache_creation_input_tokens")
    let cacheRead = tokens("cache_read_input_tokens")
    let input = tokens("input_tokens") + cacheWrite + cacheRead
    let output = tokens("output_tokens")
    let stopReason: StopReason = switch message["stop_reason"]?.stringValue {
    case "max_tokens": .maxTokens
    case "refusal": .refusal
    default: .stop
    }
    return [.assistant(AssistantEntry(
      id: Self.id(uuid),
      timestamp: at,
      content: content,
      stopReason: stopReason,
      usage: Usage(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, totalTokens: input + output),
      toolCallIDs: [:],
    ))]
  }

  private func user(_ entry: ClaudeCodeEntry, uuid: String, at: Date, joins: ClaudeCodeJoins) -> [TranscriptItem] {
    guard entry["isMeta"]?.boolValue != true, let content = entry["message"]?.object?["content"] else { return [] }
    if entry["isCompactSummary"]?.boolValue == true {
      return [.generationHead(GenerationHead(id: Self.id(uuid), timestamp: at, summary: Self.text(of: content), snapshot: StateSnapshot()))]
    }
    let blocks = content.array?.compactMap(\.object) ?? []
    let results = blocks.filter { $0["type"] == "tool_result" }
    guard results.isEmpty else {
      return results.compactMap { toolResult($0, uuid: uuid, at: at, joins: joins) }
    }
    let pieces = content.stringValue.map { [$0] } ?? blocks.compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }
    return handover(uuid, at: at, pieces: pieces, joins: joins)
  }

  func toolResult(_ block: ClaudeCodeEntry, uuid: String, at: Date, joins: ClaudeCodeJoins) -> TranscriptItem? {
    guard let callID = block["tool_use_id"]?.stringValue else { return nil }
    let text = block["content"].map(Self.text(of:)) ?? ""
    let payload: ToolResultPayload = if let receipt = joins.receipts[callID] {
      receipt
    } else if wuhuCalls.contains(callID) {
      .failure(ToolFailure(message: text))
    } else {
      .claudeCode(ClaudeCodeToolResult(text: text, isError: block["is_error"]?.boolValue == true))
    }
    return .toolResult(ToolResultItem(
      id: UUID.deterministic(uuid, callID),
      timestamp: at,
      provenance: .toolCall(ToolCallID(callID)),
      payload: payload,
    ))
  }

  // The loop's own pieces lead the handover. Its restart note is the one read
  // from the text; everything else it carried is a recorded effect.
  func handover(_ uuid: String, at: Date, pieces: [String], joins: ClaudeCodeJoins) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    if let note = Self.restartNote(in: pieces) {
      items.append(.generationHead(GenerationHead(id: UUID.deterministic(uuid, "note"), timestamp: at, summary: "", snapshot: StateSnapshot(), note: note)))
    }
    for (effect, handedOverAt) in joins.handovers[uuid] ?? [] {
      switch effect {
      case let .queue(id):
        if let input = joins.queued[id] { items.append(input.transcriptItem) }
      case let .nag(nag):
        items.append(.notification(nag.notification(id: UUID.deterministic(uuid, "nag"), at: handedOverAt)))
      case .compactionNotice:
        continue
      }
    }
    return items
  }

  private static func restartNote(in pieces: [String]) -> String? {
    for piece in pieces {
      guard let split = piece.firstRange(of: "\n\n") else { return nil }
      let header = piece[..<split.lowerBound].split(separator: "\n")
      guard header.first == "<sender>\(MessageHeader.systemSender)</sender>" else { return nil }
      if header.contains("<source>session.restart</source>") { return String(piece[split.upperBound...]) }
    }
    return nil
  }

  private static func text(of content: JSONValue) -> String {
    content.stringValue ?? (content.array ?? []).compactMap { block in
      block.object.flatMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }
    }.joined(separator: "\n")
  }

  private static func id(_ uuid: String) -> UUID {
    UUID(uuidString: uuid) ?? UUID.deterministic(uuid)
  }

  private static let wuhuPrefix = "mcp__wuhu__"
  private static let builtinNames = ["Read": "ClaudeRead", "Write": "ClaudeWrite", "Edit": "ClaudeEdit"]
}

extension Sessions {
  static func claudeCodeTranscript(_ key: String, advancing transcript: inout ClaudeCodeTranscript, in db: Database) throws -> [TranscriptItem] {
    let payloads = try SessionPointerRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(transcript.generation) && $0.position >= Int64(transcript.nextLine) }
      .order(by: \.position)
      .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
      .select { $1.payload }
      .fetchAll(db)
    let lines = payloads.map { payload in
      guard let entry = JSONValue.parse(payload)?.object else {
        preconditionFailure("session_contents holds a Claude Code entry that is not an object: \(payload)")
      }
      return entry
    }
    let kept = try Int(keptCount(key, generation: transcript.generation, in: db) ?? 0)
    return try transcript.advance(lines, kept: kept, joins: claudeCodeJoins(key, for: lines, in: db))
  }

  private static func claudeCodeJoins(_ key: String, for lines: [ClaudeCodeEntry], in db: Database) throws -> ClaudeCodeJoins {
    var joins = ClaudeCodeJoins()
    let callIDs = lines.flatMap { line in
      (line["message"]?.object?["content"]?.array ?? []).compactMap { block in
        block.object.flatMap { $0["type"] == "tool_result" ? $0["tool_use_id"]?.stringValue : nil }
      }
    }
    for chunk in callIDs.chunks {
      for receipt in try SessionReceiptRow.where({ $0.sessionID.eq(key) && $0.toolCallID.in(chunk) }).fetchAll(db) {
        joins.receipts[receipt.toolCallID] = try decode(ToolResultPayload.self, from: receipt.payload)
      }
    }
    for chunk in lines.compactMap({ $0["uuid"]?.stringValue }).chunks {
      for handover in try ClaudeCodeHandoverRow.where({ $0.sessionID.eq(key) && $0.entryUUID.in(chunk) }).fetchAll(db) {
        try joins.handovers[handover.entryUUID, default: []].append((
          decode(ClaudeCodeHandoverEffect.self, from: handover.effect),
          SQLiteDateFormat.date(from: handover.handedOverAt),
        ))
      }
    }
    let queueIDs = joins.handovers.values.flatMap { $0.compactMap { if case let .queue(id) = $0.effect { Int64(id) } else { nil } } }
    for chunk in queueIDs.chunks {
      for row in try SessionQueueRow.where({ $0.sessionID.eq(key) && $0.id.in(chunk) }).fetchAll(db) {
        joins.queued[Int(row.id)] = try decode(QueueInput.self, from: row.payload)
      }
    }
    return joins
  }
}

private extension Array {
  // Well under SQLite's bound on parameters per statement.
  var chunks: [ArraySlice<Element>] {
    stride(from: 0, to: count, by: 500).map { self[$0 ..< Swift.min($0 + 500, count)] }
  }
}
