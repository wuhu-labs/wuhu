#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import GRDB
import JSONValue
import SessionDomain
import StructuredQueries
import Synchronization

@Table("claude_code_handovers")
struct ClaudeHistoryEffect {
  @Column("rowid") var rowID: Int64
  @Column("session_id") var sessionID: String
  @Column("entry_uuid") var entryUUID: String
  var effect: String
  @Column("handed_over_at") var handedOverAt: String
}

struct ClaudeHistoryPreparationWork {
  var sourceReads = 0
  var steps = 0
  var emitted = 0
  var ready = false
}

extension SessionStore {
  /// Advances one disposable projection chunk; an unready result is retried by the viewing request owner.
  public func prepareClaudeCodeHistory(_ id: SessionID, generation: Int) async throws -> Bool {
    let cancelled = Mutex(false)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await writer.write { db in
        guard case .claudeCode = try Sessions.record(id.rawValue, in: db).executor else {
          throw ClaudeCodeStoreError.notAClaudeCodeSession(id.rawValue)
        }
        let actual = try Sessions.runtime(id.rawValue, in: db).generation
        guard Int(actual) == generation else {
          throw TranscriptHistoryError.generationChanged(expected: generation, actual: Int(actual))
        }
        return try Sessions.prepareClaudeHistoryChunk(id.rawValue, generation: actual, in: db, checkCancellation: {
          if cancelled.withLock({ $0 }) { throw CancellationError() }
        }).ready
      }
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }
}

extension Sessions {
  static func maintainClaudeHistory(_ key: String, generation: Int64, in db: Database) throws {
    guard try ClaudeHistoryProgress.where({ $0.sessionID.eq(key) }).limit(1).fetchOne(db) != nil else { return }
    _ = try prepareClaudeHistoryChunk(key, generation: generation, in: db)
  }

  static func prepareClaudeHistoryChunk(
    _ key: String, generation: Int64, in db: Database,
    maximumSourceReads: Int = 100, maximumSteps: Int = 200,
    checkCancellation: () throws -> Void = {},
  ) throws -> ClaudeHistoryPreparationWork {
    precondition(maximumSourceReads > 0 && maximumSteps > 0)
    try checkCancellation()
    let head = try claudeHistoryRawHead(key, generation: generation, in: db)
    let handoverHead = try claudeHistoryHandoverHead(key, in: db)
    var work = ClaudeHistoryPreparationWork()
    var progress = try claudeHistoryProgress(key, generation: generation, in: db)
    if progress?.version != ClaudeHistoryProgress.currentVersion || progress?.handoverHead != handoverHead {
      try discardClaudeHistory(key, generation: generation, in: db)
      progress = nil
    }
    if progress == nil {
      @Dependency(\.uuid) var uuid
      progress = ClaudeHistoryProgress(
        sessionID: key, generation: generation, version: ClaudeHistoryProgress.currentVersion, epoch: uuid().uuidString.lowercased(),
        nextLine: 0, offset: 0, count: 0, rawHead: -1, handoverHead: handoverHead, summaryPosition: -1, ready: false,
      )
      try ClaudeHistoryProgress.insert { progress! }.execute(db)
    }
    var state = progress!
    if state.ready, state.rawHead == head { work.ready = true; return work }
    let kept = try keptCount(key, generation: generation, in: db) ?? 0
    if state.nextLine == 0, state.offset == 0, kept > 0 {
      if head < kept {
        state.summaryPosition = -2
        state.rawHead = head
        state.ready = true
        try saveClaudeHistoryProgress(state, in: db)
        work.ready = true
        return work
      }
      let summary = try claudeHistorySource(key, generation: generation, position: kept, in: db)
      work.sourceReads += 1
      state.summaryPosition = summary["isCompactSummary"]?.boolValue == true ? kept : -1
    }
    state.ready = false
    while state.nextLine <= head, work.sourceReads < maximumSourceReads, work.steps < maximumSteps {
      try checkCancellation()
      let entry = try claudeHistorySource(key, generation: generation, position: state.rawPosition(), in: db)
      work.sourceReads += 1
      guard let uuid = entry["uuid"]?.stringValue else {
        state.nextLine += 1
        state.offset = 0
        continue
      }
      if state.offset == 0 {
        if try ClaudeHistorySeen.where({ $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.uuid.eq(uuid) }).fetchOne(db) != nil {
          state.nextLine += 1
          continue
        }
        try ClaudeHistorySeen.insert { ClaudeHistorySeen(sessionID: key, generation: generation, uuid: uuid) }.execute(db)
      }
      let available = maximumSteps - work.steps
      let at = entry["timestamp"]?.stringValue.flatMap(claudeCodeTimestamp) ?? .distantPast
      var translator = ClaudeCodeTranscript(generation: generation)
      var finished = true
      switch entry["type"]?.stringValue {
      case "assistant":
        if state.offset == 0 {
          for item in translator.assistant(entry, uuid: uuid, at: at) {
            try appendClaudeHistory(item, origin: nil, state: &state, work: &work, in: db)
          }
          state.offset = 1
          work.steps += 1
        }
        let origin = state.count - 1
        let calls = (entry["message"]?.object?["content"]?.array ?? []).compactMap(\.object).filter {
          $0["type"] == "tool_use" && $0["id"]?.stringValue != nil && $0["name"]?.stringValue != nil
        }
        let start = Int(state.offset - 1)
        let end = min(calls.count, start + maximumSteps - work.steps)
        for index in start ..< end {
          try checkCancellation()
          let callID = calls[index]["id"]!.stringValue!
          let name = calls[index]["name"]!.stringValue!
          let existing = try ClaudeHistoryCall.where {
            $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.callID.eq(callID)
          }.fetchOne(db)
          let wuhu = name.hasPrefix("mcp__wuhu__") || existing?.wuhu == true
          if existing != nil {
            try ClaudeHistoryCall.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.callID.eq(callID) }
              .update { $0.origin = #bind(origin); $0.wuhu = #bind(wuhu) }.execute(db)
          } else {
            try ClaudeHistoryCall.insert {
              ClaudeHistoryCall(sessionID: key, generation: generation, callID: callID, origin: origin, wuhu: wuhu)
            }.execute(db)
          }
          state.offset = Int64(index + 2)
          work.steps += 1
        }
        finished = end == calls.count
      case "user" where entry["isMeta"]?.boolValue != true && entry["message"]?.object?["content"] != nil:
        if entry["isCompactSummary"]?.boolValue == true {
          for item in translator.translate(entry, joins: ClaudeCodeJoins()) {
            try appendClaudeHistory(item, origin: nil, state: &state, work: &work, in: db)
          }
          work.steps += 1
        } else {
          let results = (entry["message"]?.object?["content"]?.array ?? []).compactMap(\.object).filter { $0["type"] == "tool_result" }
          if !results.isEmpty {
            let end = min(results.count, Int(state.offset) + available)
            for index in Int(state.offset) ..< end {
              try checkCancellation()
              let block = results[index]
              let callID = block["tool_use_id"]?.stringValue
              let call = try callID.flatMap { id in
                try ClaudeHistoryCall.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.callID.eq(id) }.fetchOne(db)
              }
              let resultTranslator = ClaudeCodeTranscript(generation: generation, wuhuCalls: call?.wuhu == true ? Set([callID!]) : [])
              if let item = resultTranslator.toolResult(block, uuid: uuid, at: at, joins: ClaudeCodeJoins()) {
                try appendClaudeHistory(item, origin: call?.origin, state: &state, work: &work, in: db)
              }
              work.steps += 1
              state.offset = Int64(index + 1)
            }
            finished = end == results.count
          } else {
            finished = try appendClaudeHistoryHandover(entry, uuid: uuid, at: at, state: &state, work: &work, maximumSteps: maximumSteps, in: db, checkCancellation: checkCancellation)
          }
        }
      case "attachment" where entry["attachment"]?.object?["type"] == "hook_additional_context":
        finished = try appendClaudeHistoryHandover(entry, uuid: uuid, at: at, state: &state, work: &work, maximumSteps: maximumSteps, in: db, checkCancellation: checkCancellation)
      default:
        work.steps += 1
      }
      if finished { state.nextLine += 1; state.offset = 0 }
    }
    try checkCancellation()
    state.rawHead = head
    state.ready = state.nextLine > head && state.offset == 0
    try saveClaudeHistoryProgress(state, in: db)
    work.ready = state.ready
    return work
  }

  private static func appendClaudeHistoryHandover(
    _ entry: ClaudeCodeEntry, uuid: String, at: Date,
    state: inout ClaudeHistoryProgress, work: inout ClaudeHistoryPreparationWork,
    maximumSteps: Int, in db: Database, checkCancellation: () throws -> Void,
  ) throws -> Bool {
    var translator = ClaudeCodeTranscript(generation: state.generation)
    if state.offset == 0 {
      for item in translator.translate(entry, joins: ClaudeCodeJoins()) {
        try appendClaudeHistory(item, origin: nil, state: &state, work: &work, in: db)
      }
      state.offset = 1
      work.steps += 1
    }
    let remaining = maximumSteps - work.steps
    guard remaining > 0 else { return false }
    let key = state.sessionID
    let after = state.offset - 1
    let effects = try ClaudeHistoryEffect
      .where { $0.sessionID.eq(key) && $0.entryUUID.eq(uuid) && $0.rowID >= after }
      .order(by: \.rowID).limit(remaining).fetchAll(db)
    for row in effects {
      try checkCancellation()
      let effect = try decode(ClaudeCodeHandoverEffect.self, from: row.effect)
      var joins = ClaudeCodeJoins()
      joins.handovers[uuid] = [(effect, try SQLiteDateFormat.date(from: row.handedOverAt))]
      if case let .queue(id) = effect,
         let payload = try SessionQueueRow.where({ $0.sessionID.eq(key) && $0.id.eq(Int64(id)) }).select(\.payload).fetchOne(db)
      {
        joins.queued[id] = try decode(QueueInput.self, from: payload)
      }
      for item in translator.handover(uuid, at: at, pieces: [], joins: joins) {
        try appendClaudeHistory(item, origin: nil, state: &state, work: &work, in: db)
      }
      state.offset = row.rowID + 2
      work.steps += 1
    }
    return effects.count < remaining
  }

  private static func appendClaudeHistory(
    _ item: TranscriptItem, origin: Int64?, state: inout ClaudeHistoryProgress,
    work: inout ClaudeHistoryPreparationWork, in db: Database,
  ) throws {
    let callID: String? = if case let .toolResult(result) = item, case let .toolCall(id) = result.provenance { id.rawValue } else { nil }
    let row = ClaudeHistoryItem(
      sessionID: state.sessionID, generation: state.generation, position: state.count,
      payload: try encode(item), origin: origin, callID: callID,
    )
    try ClaudeHistoryItem.insert { row }.execute(db)
    state.count += 1
    work.emitted += 1
  }

  private static func claudeHistorySource(_ key: String, generation: Int64, position: Int64, in db: Database) throws -> ClaudeCodeEntry {
    let payload = try SessionPointerRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.eq(position) }
      .join(SessionContentRow.all) { $0.sessionID.eq($1.sessionID) && $0.contentID.eq($1.id) }
      .select { $1.payload }.fetchOne(db)
    guard let payload, let entry = JSONValue.parse(payload)?.object else {
      preconditionFailure("Claude history source is not a committed log object")
    }
    return entry
  }

  private static func saveClaudeHistoryProgress(_ state: ClaudeHistoryProgress, in db: Database) throws {
    try ClaudeHistoryProgress.where { $0.sessionID.eq(state.sessionID) && $0.generation.eq(state.generation) }
      .update {
        $0.nextLine = #bind(state.nextLine)
        $0.offset = #bind(state.offset)
        $0.count = #bind(state.count)
        $0.rawHead = #bind(state.rawHead)
        $0.summaryPosition = #bind(state.summaryPosition)
        $0.ready = #bind(state.ready)
      }.execute(db)
  }
}
