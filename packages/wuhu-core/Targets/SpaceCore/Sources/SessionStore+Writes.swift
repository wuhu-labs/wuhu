import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import struct WuhuAI.AssistantMessage
import struct WuhuAI.AssistantMessageMetadata

extension SessionStore {
  // The receipt commits in the same transaction as the draw: a crash-retry of
  // the same tool call replays the recorded session instead of drawing again.
  @discardableResult
  public func createSession(
    group: GroupID,
    title: String,
    kind: SessionKind,
    tags: [String] = [],
    createdBy: String,
    model: ModelSpecifier,
    snapshot: StateSnapshot? = nil,
    receipt: (session: SessionID, callID: ToolCallID)? = nil,
  ) async throws -> SessionID {
    try await createSession(
      group: group, title: title, kind: kind, tags: tags, createdBy: createdBy, executor: .kernel(model),
      snapshot: snapshot, receipt: receipt,
    )
  }

  @discardableResult
  public func createSession(
    group: GroupID,
    title: String,
    kind: SessionKind,
    parent: SessionID? = nil,
    tags: [String] = [],
    createdBy: String,
    executor: SessionExecutor,
    snapshot: StateSnapshot? = nil,
    receipt: (session: SessionID, callID: ToolCallID)? = nil,
    cloneOwed: Bool = false,
  ) async throws -> SessionID {
    @Dependency(\.uuid) var uuid
    let title = try Self.usableTitle(title)
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    let tagsJSON = try Sessions.encode(tags)
    try executor.requireSupported()
    let head = snapshot.map { GenerationHead(id: uuid(), timestamp: nowDate, summary: "", snapshot: $0) }
    let minted = Allocations.mintSecretCandidate(rng)
    return try await writer.write { db in
      if let receipt,
         let recorded = try Sessions.receipt(receipt.session.rawValue, toolCallID: receipt.callID.rawValue, in: db)
      {
        guard case let .createSession(result) = recorded else {
          throw ForeignReceipt(toolCallID: receipt.callID)
        }
        return result.sessionID
      }
      if let parent {
        let parentRecord = try Sessions.record(parent.rawValue, in: db)
        guard parentRecord.lifecycle == .live, !self.archiveReservations.contains(parent) else {
          throw SessionStoreError.parentUnavailableForCreation(parent.rawValue)
        }
        guard try Sessions.ancestors(parent.rawValue, in: db).count + 2 <= Self.depthLimit else {
          throw SessionStoreError.tooDeep(parent.rawValue)
        }
      }
      let (allocation, name) = try Allocations.draw(
        .session, createdBy: createdBy, created: now, minted: minted, in: db,
      )
      try db.execute(
        sql: """
        INSERT INTO sessions (
          id, allocation, kind, parent, title, tags, created_by, executor, executor_config,
          created_at, last_activity_at, hold, work, lifecycle, run_state, grp
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'normal', 'no_work', 'live', 'no_run', ?)
        """,
        arguments: [
          name, allocation, kind.rawValue, parent?.rawValue, title, tagsJSON, createdBy,
          executor.kind, executor.configJSON, now, now, group.rawValue,
        ],
      )
      if kind == .agent {
        try Conversations.create(
          id: name, kind: .box, group: group, ownerSession: name,
          members: [.init(member: name, kind: .session)], now: now, in: db,
        )
      }
      try db.execute(
        sql: "INSERT INTO session_runtime (session_id, generation, queue_tail) VALUES (?, 0, 0)",
        arguments: [name],
      )
      try PromptRevisions.advance(name, in: db)
      // Mirrors writeCompaction's convention: a generation head counts as
      // carried, so kept_count covers it.
      try Sessions.openGeneration(name, generation: 0, keptCount: head == nil ? 0 : 1, in: db)
      if let head {
        try Sessions.append(name, generation: 0, items: [TranscriptItem.generationHead(head)], in: db)
      }
      let id = SessionID(name)
      if let receipt {
        try Sessions.recordReceipt(
          receipt.session.rawValue,
          toolCallID: receipt.callID.rawValue,
          payload: try Sessions.encode(ToolResultPayload.createSession(
            .init(sessionID: id, title: title, cloneOwed: cloneOwed ? true : nil),
          )),
          now: now,
          in: db,
        )
      }
      return id
    }
  }

  public func enqueue(_ id: SessionID, input: QueueInput) async throws -> Int {
    let key = id.rawValue
    let nowDate = dateGen.now
    let row = try await writer.write { db in
      try Sessions.enqueue(key, input: input, nowDate: nowDate, in: db)
    }
    signals.post(id)
    return row
  }

  // A drained input is unanswered by construction — it lands after any
  // assistant entry — so the work flag follows from having drained anything
  // and needs no transcript.
  public func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      let runtime = try Sessions.runtime(key, in: db)
      let entries = try Sessions.undrained(key, tail: runtime.queueTail, in: db)
      guard let lastID = entries.last?.id else {
        return QueueDrain(items: [], queueTail: Int(runtime.queueTail))
      }
      let items = entries.map(\.input.transcriptItem)
      try Sessions.append(key, generation: runtime.generation, items: items, in: db)
      try db.execute(
        sql: "UPDATE session_runtime SET queue_tail = ? WHERE session_id = ?",
        arguments: [lastID, key],
      )
      try Sessions.markDrained(key, through: Int64(lastID), now: now, in: db)
      try Sessions.markHasWork(key, now: now, in: db)
      return QueueDrain(items: items, queueTail: lastID)
    }
  }

  // `transcript` is the caller's state with `items` already appended: the work
  // flag is derived from the whole generation, and reading it back here would
  // decode every payload in the session under the space's one write lock.
  public func append(_ id: SessionID, items: [TranscriptItem], transcript: Transcript) async throws {
    guard !items.isEmpty else { return }
    precondition(
      transcript.items.suffix(items.count).map(\.id) == items.map(\.id),
      "append takes the transcript that already carries those items",
    )
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      let runtime = try Sessions.runtime(key, in: db)
      try Sessions.append(key, generation: runtime.generation, items: items, in: db)
      try Sessions.refreshWork(key, transcript: transcript, now: now, in: db)
    }
  }

  public func writeCompaction(
    _ id: SessionID,
    closing: ToolResultItem? = nil,
    head: GenerationHead,
    kept: Range<Int>?,
  ) async throws -> Transcript {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db -> Transcript in
      let runtime = try Sessions.runtime(key, in: db)
      let transcript = try Sessions.transcript(key, in: db)
      // The closing result joins the OLD generation in the same commit; the
      // kept range never includes it (it was computed before the close).
      if let closing {
        try Sessions.append(key, generation: runtime.generation, items: [TranscriptItem.toolResult(closing)], in: db)
      }
      let compacted = transcript.compacted(head: head, kept: kept)
      let generation = runtime.generation + 1
      try Sessions.writeGeneration(key, generation: generation, transcript: compacted, in: db)
      try Sessions.refreshWork(key, transcript: compacted, now: now, in: db)
      try PromptRevisions.advance(key, in: db)
      return compacted
    }
  }

  // One line, trimmed, capped: the title is a row every roster and dashboard
  // renders, so a wall of prose would be someone else's broken layout.
  public static let titleLimit: Int = 200

  // A root is level 1; a session at level depthLimit + 1 is refused.
  public static let depthLimit: Int = 16

  public static func usableTitle(_ title: String) throws(SessionStoreError) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count <= Self.titleLimit, !cleaned.contains(where: \.isNewline) else {
      throw .unusableTitle(title)
    }
    return cleaned
  }

  public func setTitle(_ id: SessionID, to title: String) async throws -> String {
    let cleaned = try Self.usableTitle(title)
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(
        sql: "UPDATE sessions SET title = ?, last_activity_at = ? WHERE id = ?",
        arguments: [cleaned, now, key],
      )
    }
    return cleaned
  }

  // The whole list is replaced, whatever the session's lifecycle: an archived
  // session can be retagged to tidy history.
  public func setTags(_ id: SessionID, to tags: [String]) async throws {
    let key = id.rawValue
    let encoded = try Sessions.encode(tags)
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(sql: "UPDATE sessions SET tags = ? WHERE id = ?", arguments: [encoded, key])
    }
  }

  // Archive, unarchive, interrupt, resume and tag edits on a session belong to
  // the session itself and its ancestors. Humans are let through at their own
  // door, never here.
  public func refuseControl(of target: SessionID, by actor: SessionID) async throws {
    try await writer.read { db in
      _ = try Sessions.record(target.rawValue, in: db)
      guard try actor == target || Sessions.ancestors(target.rawValue, in: db).contains(actor.rawValue) else {
        throw SessionStoreError.notInCharge(target.rawValue, actor: actor.rawValue)
      }
    }
  }

  /// Archive and unarchive: the session itself, its creator (an ancestor, or
  /// whoever created it top-level), or an admin of its group. The --dev seat
  /// is unrestricted.
  public func refuseArchiving(_ target: SessionID, by actor: Actor) async throws {
    try await writer.read { db in
      let record = try Sessions.record(target.rawValue, in: db)
      let allowed: Bool
      let label: String
      switch actor {
      case let .session(id):
        label = id.rawValue
        allowed = try id == target || record.createdBy == id.rawValue
          || Sessions.ancestors(target.rawValue, in: db).contains(id.rawValue)
          || Groups.isAdmin(actor, of: record.group, in: db)
      case let .person(persona, account):
        label = persona
        allowed = try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM personas WHERE name = ? AND account_id = ?)",
          arguments: [record.createdBy, account.rawValue],
        ) == true || Groups.isHumanAdmin(account, of: record.group, in: db)
      case .anonymous:
        label = "anonymous"
        allowed = true
      }
      guard allowed else { throw SessionStoreError.mayNotArchive(target.rawValue, actor: label) }
    }
  }

  public func markInterrupted(_ id: SessionID) async throws {
    try await setHold(id, to: .interrupted)
  }

  public func markResumed(_ id: SessionID) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let reminderQueued = try await writer.write { db -> Bool in
      let record = try Sessions.record(key, in: db)
      try record.executor.requireSupported()
      try db.execute(
        sql: "UPDATE sessions SET hold = 'normal', error_message = NULL, last_activity_at = ? WHERE id = ?",
        arguments: [now, key],
      )
      if record.work == .errored {
        try db.execute(sql: "UPDATE sessions SET work = 'no_work' WHERE id = ?", arguments: [key])
        let transcript = switch record.executor {
        case .kernel, .contractor: try Sessions.transcript(key, in: db)
        case .claudeCode: Transcript()
        }
        try Sessions.refreshWork(key, transcript: transcript, now: now, in: db)
      }
      return false
    }
    if reminderQueued { signals.post(id) }
  }

  public func markErrored(_ id: SessionID, message: String) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let parent = try await writer.write { db -> SessionID? in
      let record: SessionRecord?
      do {
        record = try Sessions.record(key, in: db)
      } catch where isUnreadableSessionData(error) {
        record = nil
      }
      try db.execute(
        sql: "UPDATE sessions SET work = 'errored', error_message = ?, last_activity_at = ? WHERE id = ?",
        arguments: [message, now, key],
      )
      let parent: SessionID?
      do {
        parent = record == nil ? nil : try self.notifyParentOfFailure(key, error: message, now: now, in: db)
      } catch where isUnreadableSessionData(error) {
        parent = nil
      }
      guard let parent else {
        let transcript: Transcript
        do {
          transcript = switch record?.executor {
          case .kernel, .contractor: try Sessions.transcript(key, in: db)
          case .claudeCode, nil: Transcript()
          }
        } catch where isUnreadableSessionData(error) {
          transcript = Transcript()
        }
        try Notifications.fireErrored(key, error: message, transcript: transcript, now: now, in: db)
        return nil
      }
      return parent
    }
    if let parent {
      signals.post(parent)
    }
  }

  @discardableResult
  public func archive(_ id: SessionID, grace: Duration) async throws -> Date {
    let key = id.rawValue
    let nowDate = dateGen.now
    let deadline = nowDate.addingTimeInterval(grace.timeInterval)
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(
        sql: "UPDATE sessions SET lifecycle = 'archived', grace_expires_at = ?, last_activity_at = ? WHERE id = ?",
        arguments: [SQLiteDateFormat.string(from: deadline), SQLiteDateFormat.string(from: nowDate), key],
      )
    }
    return deadline
  }

  public func unarchive(_ id: SessionID) async throws {
    let key = id.rawValue
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    try await writer.write { db in
      let record = try Sessions.record(key, in: db)
      guard case let .archived(graceExpiresAt) = record.lifecycle else { return }
      guard nowDate < graceExpiresAt else { throw SessionStoreError.archiveGraceExpired(key) }
      try db.execute(
        sql: "UPDATE sessions SET lifecycle = 'live', grace_expires_at = NULL, last_activity_at = ? WHERE id = ?",
        arguments: [now, key],
      )
    }
  }

  // The template's files reached the home: a replay of this creation no
  // longer clones them.
  public func settleClone(_ id: SessionID, toolCallID: ToolCallID) async throws {
    let key = id.rawValue
    try await writer.write { db in
      guard case var .createSession(result)? = try Sessions.receipt(key, toolCallID: toolCallID.rawValue, in: db),
            result.cloneOwed == true
      else { return }
      result.cloneOwed = nil
      try db.execute(
        sql: "UPDATE session_receipts SET payload = ? WHERE session_id = ? AND tool_call_id = ?",
        arguments: [try Sessions.encode(ToolResultPayload.createSession(result)), key, toolCallID.rawValue],
      )
    }
  }

  public func recordReceipt(_ id: SessionID, toolCallID: ToolCallID, payload: ToolResultPayload) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let encoded = try Sessions.encode(payload)
    try await writer.write { db in
      try Sessions.recordReceipt(key, toolCallID: toolCallID.rawValue, payload: encoded, now: now, in: db)
    }
  }

  private func setHold(_ id: SessionID, to hold: SessionHold) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      _ = try Sessions.record(key, in: db)
      try db.execute(
        sql: "UPDATE sessions SET hold = ?, last_activity_at = ? WHERE id = ?",
        arguments: [hold.rawValue, now, key],
      )
    }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}

extension Sessions {
  static func writeGeneration(_ key: String, generation: Int64, transcript: Transcript, in db: Database) throws {
    guard case let .generationHead(head)? = transcript.items.first else {
      preconditionFailure("a generation must open with its head")
    }
    try openGeneration(key, generation: generation, keptCount: transcript.keptCount, in: db)
    try db.execute(
      sql: "INSERT INTO session_contents (session_id, id, payload) VALUES (?, ?, ?)",
      arguments: [key, head.id.uuidString.lowercased(), try encode(TranscriptItem.generationHead(head))],
    )
    for (position, item) in transcript.items.enumerated() {
      try db.execute(
        sql: "INSERT INTO session_pointers (session_id, generation, position, content_id) VALUES (?, ?, ?, ?)",
        arguments: [key, generation, position, item.id.uuidString.lowercased()],
      )
    }
  }
}
