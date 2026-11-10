import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
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
    receipt: (holder: Caller, callID: ToolCallID)? = nil,
  ) async throws -> SessionID {
    try await createSession(
      group: group, title: title, kind: kind, tags: tags, createdBy: createdBy, executor: .kernel(model),
      snapshot: snapshot, receipt: receipt,
    )
  }

  /// An `observer` records its firing on the session and is admitted under
  /// its hourly cap in the write that creates it; a replayed receipt is not
  /// admitted again.
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
    receipt: (holder: Caller, callID: ToolCallID)? = nil,
    cloneOwed: Bool = false,
    modelRoute: SessionModelRoute? = nil,
    request: (id: RequestID, requester: Caller, brief: String, terms: RequestTerms, stallSeconds: Double?)? = nil,
    observer: Observer? = nil,
  ) async throws -> SessionID {
    @Dependency(\.uuid) var uuid
    let title = try Self.usableTitle(title)
    let nowDate = dateGen.now
    let now = SQLiteDateFormat.string(from: nowDate)
    let tagsJSON = try Sessions.encode(tags)
    try executor.requireSupported()
    let storedExecutor = try Sessions.concreteExecutor(executor, route: modelRoute)
    let head = snapshot.map { GenerationHead(id: uuid(), timestamp: nowDate, summary: "", snapshot: $0, runningWork: []) }
    let minted = Allocations.mintSecretCandidate(rng)
    let made = try await writer.write { db -> Result<SessionID, ObserverRefusal> in
      if let receipt,
         let recorded = try Sessions.receipt(receipt.holder.receiptHolder, toolCallID: receipt.callID.rawValue, in: db)
      {
        guard case let .createSession(result) = recorded else {
          throw ForeignReceipt(toolCallID: receipt.callID)
        }
        return .success(result.sessionID)
      }
      if let observer, let refusal = try Self.admit(observer, now: nowDate, in: db) { return .failure(refusal) }
      if let parent {
        let parentRecord = try Sessions.record(parent.rawValue, in: db)
        guard parentRecord.lifecycle == .live else {
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
          created_at, last_activity_at, hold, work, lifecycle, run_state, grp, firing
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'normal', 'no_work', 'live', 'no_run', ?, ?)
        """,
        arguments: [
          name, allocation, kind.rawValue, parent?.rawValue, title, tagsJSON, createdBy,
          storedExecutor.kind, storedExecutor.configJSON, now, now, group.rawValue, observer?.firing,
        ],
      )
      try Sessions.writeModelRoute(name, route: modelRoute, in: db)
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
      try SessionPrompts.advance(name, in: db)
      // Mirrors writeCompaction's convention: a generation head counts as
      // carried, so kept_count covers it.
      try Sessions.openGeneration(name, generation: 0, keptCount: head == nil ? 0 : 1, in: db)
      if let head {
        try Sessions.append(name, generation: 0, items: [TranscriptItem.generationHead(head)], in: db)
      }
      let id = SessionID(name)
      if let parent { try Self.watchChildren(parent, now: now, in: db) }
      if let request {
        try Self.insertRequest(
          request.id, group: group, requester: request.requester, task: id, brief: request.brief, terms: request.terms,
          stallSeconds: request.stallSeconds, now: now, in: db,
        )
      }
      if let receipt {
        try Sessions.recordReceipt(
          receipt.holder.receiptHolder,
          toolCallID: receipt.callID.rawValue,
          payload: try Sessions.encode(ToolResultPayload.createSession(
            .init(sessionID: id, title: title, cloneOwed: cloneOwed ? true : nil, modelGroup: modelRoute?.group, member: modelRoute?.member, provider: modelRoute?.specifier.provider, model: modelRoute?.specifier.model),
          )),
          now: now,
          in: db,
        )
      }
      return .success(id)
    }
    return try made.get()
  }

  /// Mails the session's cell an input for its queue.
  public func enqueue(_ id: SessionID, input: QueueInput, topic: String? = nil, due: Date? = nil) async throws {
    let key = id.rawValue
    let nowDate = dateGen.now
    try await writer.write { db in
      try Sessions.enqueue(key, input: input, topic: topic, due: due, nowDate: nowDate, in: db)
    }
    signals.post(id)
  }

  /// Mails the session's cell to take back the input on `topic` that the model has not seen.
  public func clear(_ id: SessionID, topic: String) async throws {
    let key = id.rawValue
    try await writer.write { db in try Sessions.clear(key, topic: topic, in: db) }
    signals.post(id)
  }

  public func drainQueue(_ id: SessionID) async throws -> QueueDrain {
    try await rows { try $0.drainQueue(id) }
  }

  public func append(_ id: SessionID, items: [TranscriptItem], inputOrigin: Bool?) async throws {
    try await rows { try $0.append(id, items: items, inputOrigin: inputOrigin) }
  }

  public func writeCompaction(_ id: SessionID, closing: ToolResultItem? = nil, head: GenerationHead, kept: Range<Int>?, transition: ModelRouteTransition? = nil) async throws -> Transcript {
    try await rows { try $0.writeCompaction(id, closing: closing, head: head, kept: kept, transition: transition) }
  }

  // One line, trimmed, capped: the title is a row every roster and dashboard
  // renders, so a wall of prose would be someone else's broken layout.
  public static let titleLimit: Int = SessionTitle.maximumCharacters

  // A root is level 1; a session at level depthLimit + 1 is refused.
  public static let depthLimit: Int = 16

  public static func usableTitle(_ title: String) throws(SessionStoreError) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count <= Self.titleLimit, !cleaned.contains(where: \.isNewline) else {
      throw .unusableTitle(title)
    }
    return cleaned
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
  public func refuseArchiving(_ target: SessionID, by actor: Actor, acting: GroupID) async throws {
    try await writer.read { db in
      let record = try Sessions.record(target.rawValue, in: db)
      let admin = try GroupAccess.role(of: actor, in: record.group, acting: acting, in: db) == .admin
      let allowed: Bool
      let label: String
      switch actor {
      case let .session(id):
        label = id.rawValue
        allowed = try id == target || record.createdBy == id.rawValue
          || Sessions.ancestors(target.rawValue, in: db).contains(id.rawValue)
          || admin
      case let .person(persona, account):
        label = persona
        allowed = try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM personas WHERE name = ? AND account_id = ?)",
          arguments: [record.createdBy, account.rawValue],
        ) == true || admin
      case let .observer(observer):
        label = observer.member
        allowed = record.createdBy == observer.member || admin
      case let .page(page):
        label = page.path.rawValue
        allowed = false
      case .anonymous:
        label = "anonymous"
        allowed = true
      }
      guard allowed else { throw SessionStoreError.mayNotArchive(target.rawValue, actor: label) }
    }
  }

  public func markErrored(_ id: SessionID, message: String) async throws {
    try await rows { try $0.markErrored(id, message: message) }
  }

  // The template's files reached the home: a replay of this creation no
  // longer clones them.
  public func settleClone(_ holder: Caller, toolCallID: ToolCallID) async throws {
    let key = holder.receiptHolder
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

  public func recordReceipt(_ id: SessionID, toolCallID: ToolCallID, payload: ToolResultPayload, onCommit: @escaping @Sendable () -> Void = {}) async throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: dateGen.now)
    let encoded = try Sessions.encode(payload)
    try await writer.write { db in
      try Sessions.recordReceipt(key, toolCallID: toolCallID.rawValue, payload: encoded, now: now, in: db)
      db.afterNextTransaction { _ in onCommit() }
    }
  }
}

extension Duration {
  var timeInterval: TimeInterval {
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
    try writeLines(key, generation: generation, appending: transcript.items, after: 0, in: db)
  }
}
