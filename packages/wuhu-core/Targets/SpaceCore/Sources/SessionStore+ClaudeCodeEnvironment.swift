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

// One row per thing a confirming log entry carried: a queue row it delivered,
// or a nag it showed. Written when the mirror confirms the handover.
let claudeCodeHandoverSchemaSQL = """
CREATE TABLE IF NOT EXISTS "claude_code_handovers" (
  "session_id" TEXT NOT NULL,
  "entry_uuid" TEXT NOT NULL,
  "effect" TEXT NOT NULL,
  "handed_over_at" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "claude_code_handovers_by_entry" ON "claude_code_handovers" ("session_id", "entry_uuid");
"""

@Table("claude_code_handovers")
struct ClaudeCodeHandoverRow {
  @Column("session_id") var sessionID: String
  @Column("entry_uuid") var entryUUID: String
  @Column("effect") var effect: String
  @Column("handed_over_at") var handedOverAt: String
}

@Table("session_receipts")
struct SessionReceiptRow {
  @Column("session_id") var sessionID: String
  @Column("tool_call_id") var toolCallID: String
  @Column("payload") var payload: String
  @Column("recorded_at") var recordedAt: String
}

@Table("session_queue")
struct SessionQueueRow {
  @Column("session_id") var sessionID: String
  @Column("id") var id: Int64
  @Column("payload") var payload: String
}

enum ClaudeCodeHandoverEffect: Codable, Hashable {
  case queue(Int)
  case nag(Nag)
  case compactionNotice
}

extension SessionStore {
  // `pendingSince`: the handover time of the running turn. Its tool calls may
  // not be in the stored log yet (Claude Code flushes a fast turn after its
  // end-of-turn hook); their receipts follow everything stored.
  public func claudeCodeEnvironment(_ id: SessionID, pendingSince: Date? = nil) async throws -> SessionEnvironment {
    let key = id.rawValue
    return try await writer.read { db in
      try Sessions.claudeCodeEnvironment(key, generation: Sessions.runtime(key, in: db).generation, pendingSince: pendingSince, in: db)
    }
  }
}

extension Sessions {
  static func claudeCodeEnvironment(_ key: String, generation: Int64, pendingSince: Date?, in db: Database) throws -> SessionEnvironment {
    let row = try ClaudeCodeSessionRow.where { $0.sessionID.eq(key) }.fetchOne(db)
    let snapshot = try row?.environment.map { try decode(SessionEnvironment.self, from: $0) }
    // A snapshot already holds the entries the boundary carried across.
    let skipped = snapshot == nil ? 0 : try Sessions.keptCount(key, generation: generation, in: db) ?? 0
    let payloads = try SessionPointerRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position >= skipped }
      .order(by: \.position)
      .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
      .select { $1.payload }
      .fetchAll(db)

    var handovers: [String: [(ClaudeCodeHandoverEffect, Date)]] = [:]
    for handover in try ClaudeCodeHandoverRow.where({ $0.sessionID.eq(key) }).fetchAll(db) {
      handovers[handover.entryUUID, default: []].append((
        try decode(ClaudeCodeHandoverEffect.self, from: handover.effect),
        try SQLiteDateFormat.date(from: handover.handedOverAt),
      ))
    }
    var receipts: [String: (payload: String, recordedAt: String)] = [:]
    for receipt in try SessionReceiptRow.where({ $0.sessionID.eq(key) }).fetchAll(db) {
      receipts[receipt.toolCallID] = (receipt.payload, receipt.recordedAt)
    }
    func queued(_ id: Int) throws -> QueueInput? {
      try SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.eq(Int64(id)) }.select(\.payload).fetchOne(db)
        .map { try decode(QueueInput.self, from: $0) }
    }

    var environment = snapshot ?? SessionEnvironment()
    var referenced: Set<String> = []
    for payload in payloads {
      guard let entry = JSONValue.parse(payload)?.object else { continue }
      let at = entry["timestamp"]?.stringValue.flatMap(claudeCodeTimestamp) ?? .distantPast
      if let uuid = entry["uuid"]?.stringValue {
        for (effect, handedOverAt) in handovers[uuid] ?? [] {
          switch effect {
          case let .queue(id):
            if let input = try queued(id) { environment.apply(.delivered(input, at: handedOverAt)) }
          case let .nag(nag):
            environment.apply(.nagged(nag, at: handedOverAt))
          case .compactionNotice:
            break
          }
        }
      }
      guard entry["type"] == "user", let blocks = entry["message"]?.object?["content"]?.array else { continue }
      for block in blocks {
        guard let fields = block.object, fields["type"] == "tool_result",
              let toolCallID = fields["tool_use_id"]?.stringValue
        else { continue }
        referenced.insert(toolCallID)
        guard let receipt = receipts[toolCallID] else { continue }
        environment.apply(.toolResult(try decode(ToolResultPayload.self, from: receipt.payload), at: at))
      }
    }
    if let pendingSince {
      let since = SQLiteDateFormat.string(from: pendingSince)
      for (toolCallID, receipt) in receipts.sorted(by: { $0.value.recordedAt < $1.value.recordedAt })
        where receipt.recordedAt >= since && !referenced.contains(toolCallID)
      {
        environment.apply(.toolResult(try decode(ToolResultPayload.self, from: receipt.payload), at: try SQLiteDateFormat.date(from: receipt.recordedAt)))
      }
    }
    return environment
  }

  static func recordClaudeCodeHandover(
    _ key: String,
    entry: String,
    effects: [ClaudeCodeHandoverEffect],
    at handedOverAt: Date,
    in db: Database,
  ) throws {
    let at = SQLiteDateFormat.string(from: handedOverAt)
    for effect in effects {
      let encoded = try encode(effect)
      try ClaudeCodeHandoverRow.insert {
        ClaudeCodeHandoverRow(sessionID: key, entryUUID: entry, effect: encoded, handedOverAt: at)
      }.execute(db)
    }
  }
}

func claudeCodeTimestamp(_ text: String) -> Date? {
  try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
}
