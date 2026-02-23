import Foundation
import GRDB
import PiAI
import WuhuAPI

public actor SQLiteSessionStore: SessionStore {
  private let dbQueue: DatabaseQueue

  public init(path: String) throws {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)

    dbQueue = try DatabaseQueue(path: path, configuration: config)
    try Self.migrator.migrate(dbQueue)
  }

  public func createEnvironment(_ request: WuhuCreateEnvironmentRequest) async throws -> WuhuEnvironmentDefinition {
    let now = Date()
    let id = UUID().uuidString.lowercased()

    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let path = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
    let templatePath = request.templatePath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let startupScript = request.startupScript?.trimmingCharacters(in: .whitespacesAndNewlines)

    return try await dbQueue.write { db in
      var row = EnvironmentRow(
        id: id,
        name: name,
        type: request.type.rawValue,
        path: path,
        templatePath: templatePath?.isEmpty == false ? templatePath : nil,
        startupScript: startupScript?.isEmpty == false ? startupScript : nil,
        createdAt: now,
        updatedAt: now,
      )
      try row.insert(db)
      return try row.toModel()
    }
  }

  public func listEnvironments() async throws -> [WuhuEnvironmentDefinition] {
    try await dbQueue.read { db in
      try EnvironmentRow
        .order(Column("name").asc)
        .fetchAll(db)
        .map { try $0.toModel() }
    }
  }

  public func getEnvironment(identifier raw: String) async throws -> WuhuEnvironmentDefinition {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw WuhuEnvironmentResolutionError.unknownEnvironment(raw) }

    return try await dbQueue.read { db in
      let row: EnvironmentRow? = if UUID(uuidString: identifier) != nil {
        try EnvironmentRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try EnvironmentRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard let row else {
        throw WuhuEnvironmentResolutionError.unknownEnvironment(identifier)
      }
      return try row.toModel()
    }
  }

  public func updateEnvironment(
    identifier raw: String,
    request: WuhuUpdateEnvironmentRequest,
  ) async throws -> WuhuEnvironmentDefinition {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw WuhuEnvironmentResolutionError.unknownEnvironment(raw) }

    let now = Date()
    return try await dbQueue.write { db in
      let row: EnvironmentRow? = if UUID(uuidString: identifier) != nil {
        try EnvironmentRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try EnvironmentRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard var row else {
        throw WuhuEnvironmentResolutionError.unknownEnvironment(identifier)
      }

      if let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
        row.name = name
      }
      if let type = request.type {
        row.type = type.rawValue
      }
      if let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
        row.path = path
      }
      if let templatePath = request.templatePath {
        let trimmed = templatePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        row.templatePath = (trimmed?.isEmpty == false) ? trimmed : nil
      }
      if let startupScript = request.startupScript {
        let trimmed = startupScript?.trimmingCharacters(in: .whitespacesAndNewlines)
        row.startupScript = (trimmed?.isEmpty == false) ? trimmed : nil
      }

      row.updatedAt = now
      try row.update(db)
      return try row.toModel()
    }
  }

  public func deleteEnvironment(identifier raw: String) async throws {
    let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { throw WuhuEnvironmentResolutionError.unknownEnvironment(raw) }

    try await dbQueue.write { db in
      let row: EnvironmentRow? = if UUID(uuidString: identifier) != nil {
        try EnvironmentRow.fetchOne(db, key: identifier.lowercased())
      } else {
        try EnvironmentRow.filter(Column("name") == identifier).fetchOne(db)
      }

      guard let row else {
        throw WuhuEnvironmentResolutionError.unknownEnvironment(identifier)
      }
      _ = try row.delete(db)
    }
  }

  public func createSession(
    sessionID rawSessionID: String,
    sessionType: WuhuSessionType,
    provider: WuhuProvider,
    model: String,
    reasoningEffort: ReasoningEffort?,
    systemPrompt: String,
    environmentID: String?,
    environment: WuhuEnvironment,
    runnerName: String?,
    parentSessionID: String?,
  ) async throws -> WuhuSession {
    let now = Date()
    let sessionID = rawSessionID.lowercased()

    let skills = WuhuSkillsLoader.load(environmentRoot: environment.path)
    let effectiveSystemPrompt: String = {
      if skills.isEmpty { return systemPrompt }
      return systemPrompt + WuhuSkills.promptSection(skills: skills)
    }()

    return try await dbQueue.write { db in
      var sessionRow = SessionRow(
        id: sessionID,
        sessionType: sessionType.rawValue,
        provider: provider.rawValue,
        model: model,
        effectiveReasoningEffort: reasoningEffort?.rawValue,
        pendingProvider: nil,
        pendingModel: nil,
        pendingReasoningEffort: nil,
        executionStatus: SessionExecutionStatus.idle.rawValue,
        environmentID: environmentID?.lowercased(),
        environmentName: environment.name,
        environmentType: environment.type.rawValue,
        environmentPath: environment.path,
        environmentTemplatePath: environment.templatePath,
        environmentStartupScript: environment.startupScript,
        cwd: environment.path,
        runnerName: runnerName,
        parentSessionID: parentSessionID,
        displayStartEntryID: nil,
        createdAt: now,
        updatedAt: now,
        headEntryID: nil,
        tailEntryID: nil,
      )
      try sessionRow.insert(db)

      var headerMetadata: [String: JSONValue] = [:]
      if let reasoningEffort {
        headerMetadata["reasoningEffort"] = .string(reasoningEffort.rawValue)
      }
      if !skills.isEmpty {
        headerMetadata[WuhuSkills.headerMetadataKey] = WuhuSkills.encodeForHeaderMetadata(skills)
      }
      let headerPayload = WuhuEntryPayload.header(.init(
        systemPrompt: effectiveSystemPrompt,
        metadata: .object(headerMetadata),
      ))
      var headerRow = try EntryRow.new(
        sessionID: sessionID,
        parentEntryID: nil,
        payload: headerPayload,
        createdAt: now,
      )
      try headerRow.insert(db)
      guard let headerID = headerRow.id else {
        throw WuhuStoreError.sessionCorrupt("Failed to create header entry id")
      }

      sessionRow.headEntryID = headerID
      sessionRow.tailEntryID = headerID
      try sessionRow.update(db)

      return try sessionRow.toModel()
    }
  }

  public func getSession(id: String) async throws -> WuhuSession {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: id) else {
        throw WuhuStoreError.sessionNotFound(id)
      }
      return try row.toModel()
    }
  }

  public func listSessions(limit: Int? = nil) async throws -> [WuhuSession] {
    try await dbQueue.read { db in
      var req = SessionRow.order(Column("updatedAt").desc)
      if let limit { req = req.limit(limit) }
      return try req.fetchAll(db).map { try $0.toModel() }
    }
  }

  // MARK: - Channels / Forking

  struct ChildSessionRecord: Sendable, Hashable {
    var session: WuhuSession
    var executionStatus: SessionExecutionStatus
    var lastNotifiedFinalEntryID: Int64?
    var lastReadFinalEntryID: Int64?

    var hasUnreadFinalMessage: Bool {
      guard let lastNotifiedFinalEntryID else { return false }
      let lastRead = lastReadFinalEntryID ?? 0
      return lastNotifiedFinalEntryID > lastRead
    }
  }

  func listChildSessions(parentSessionID: String) async throws -> [ChildSessionRecord] {
    try await dbQueue.read { db in
      let sessionRows = try SessionRow
        .filter(Column("parentSessionID") == parentSessionID)
        .order(Column("updatedAt").desc)
        .fetchAll(db)

      let statusRows = try SessionChildStatusRow
        .filter(Column("parentSessionID") == parentSessionID)
        .fetchAll(db)
      var statusByChild: [String: SessionChildStatusRow] = [:]
      statusByChild.reserveCapacity(statusRows.count)
      for row in statusRows {
        statusByChild[row.childSessionID] = row
      }

      return try sessionRows.map { row in
        let exec = SessionExecutionStatus(rawValue: row.executionStatus) ?? .idle
        let session = try row.toModel()
        let status = statusByChild[row.id]
        return .init(
          session: session,
          executionStatus: exec,
          lastNotifiedFinalEntryID: status?.lastNotifiedFinalEntryID,
          lastReadFinalEntryID: status?.lastReadFinalEntryID,
        )
      }
    }
  }

  func setChildFinalMessageNotified(
    parentSessionID: String,
    childSessionID: String,
    finalEntryID: Int64,
  ) async throws -> Bool {
    let now = Date()
    return try await dbQueue.write { db in
      let existing = try SessionChildStatusRow
        .filter(Column("parentSessionID") == parentSessionID && Column("childSessionID") == childSessionID)
        .fetchOne(db)
      if existing?.lastNotifiedFinalEntryID == finalEntryID {
        return false
      }

      try db.execute(
        sql: """
        INSERT INTO session_child_status (parentSessionID, childSessionID, lastNotifiedFinalEntryID, lastReadFinalEntryID, updatedAt)
        VALUES (?, ?, ?, COALESCE((SELECT lastReadFinalEntryID FROM session_child_status WHERE parentSessionID = ? AND childSessionID = ?), NULL), ?)
        ON CONFLICT(parentSessionID, childSessionID)
        DO UPDATE SET lastNotifiedFinalEntryID = excluded.lastNotifiedFinalEntryID, updatedAt = excluded.updatedAt
        """,
        arguments: [parentSessionID, childSessionID, finalEntryID, parentSessionID, childSessionID, now],
      )
      return true
    }
  }

  func markChildFinalMessageRead(
    parentSessionID: String,
    childSessionID: String,
    finalEntryID: Int64,
  ) async throws {
    let now = Date()
    try await dbQueue.write { db in
      try db.execute(
        sql: """
        INSERT INTO session_child_status (parentSessionID, childSessionID, lastNotifiedFinalEntryID, lastReadFinalEntryID, updatedAt)
        VALUES (?, ?, NULL, ?, ?)
        ON CONFLICT(parentSessionID, childSessionID)
        DO UPDATE SET lastReadFinalEntryID = excluded.lastReadFinalEntryID, updatedAt = excluded.updatedAt
        """,
        arguments: [parentSessionID, childSessionID, finalEntryID, now],
      )
    }
  }

  func setDisplayStartEntryID(sessionID: String, entryID: Int64?) async throws {
    try await dbQueue.write { db in
      try db.execute(
        sql: "UPDATE sessions SET displayStartEntryID = ?, updatedAt = ? WHERE id = ?",
        arguments: [entryID, Date(), sessionID],
      )
    }
  }

  @discardableResult
  public func appendEntry(sessionID: String, payload: WuhuEntryPayload) async throws -> WuhuSessionEntry {
    let (_, entry) = try await appendEntryWithSession(
      sessionID: SessionID(rawValue: sessionID),
      payload: payload,
      createdAt: Date(),
    )
    return entry
  }

  public func getEntries(sessionID: String) async throws -> [WuhuSessionEntry] {
    try await dbQueue.read { db in
      guard let sessionRow = try SessionRow.fetchOne(db, key: sessionID) else {
        throw WuhuStoreError.sessionNotFound(sessionID)
      }
      let session = try sessionRow.toModel()
      let rows = try EntryRow
        .filter(Column("sessionID") == sessionID)
        .fetchAll(db)
      let entries = rows.map { $0.toModel() }
      return try Self.linearize(
        entries: entries,
        sessionID: sessionID,
        headEntryID: session.headEntryID,
        tailEntryID: session.tailEntryID,
      )
    }
  }

  public func getEntries(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
  ) async throws -> [WuhuSessionEntry] {
    try await dbQueue.read { db in
      guard let _ = try SessionRow.fetchOne(db, key: sessionID) else {
        throw WuhuStoreError.sessionNotFound(sessionID)
      }

      var filter = Column("sessionID") == sessionID
      if let sinceCursor {
        filter = filter && Column("id") > sinceCursor
      }
      if let sinceTime {
        filter = filter && Column("createdAt") > sinceTime
      }

      var req = EntryRow.filter(filter)
      req = req.order(Column("id").asc)
      return try req.fetchAll(db).map { $0.toModel() }
    }
  }

  private static func linearize(
    entries: [WuhuSessionEntry],
    sessionID: String,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) throws -> [WuhuSessionEntry] {
    var byID: [Int64: WuhuSessionEntry] = [:]
    byID.reserveCapacity(entries.count)

    var childByParent: [Int64: WuhuSessionEntry] = [:]
    childByParent.reserveCapacity(entries.count)

    var header: WuhuSessionEntry?
    for entry in entries {
      byID[entry.id] = entry
      if let parent = entry.parentEntryID {
        childByParent[parent] = entry
      } else {
        header = entry
      }
    }

    guard let header else { throw WuhuStoreError.noHeaderEntry(sessionID) }
    guard header.id == headEntryID else {
      throw WuhuStoreError.sessionCorrupt("headEntryID=\(headEntryID) does not match header.id=\(header.id)")
    }

    var ordered: [WuhuSessionEntry] = []
    ordered.reserveCapacity(entries.count)

    var current = header
    ordered.append(current)
    var seen = Set<Int64>()
    seen.insert(current.id)

    while let child = childByParent[current.id] {
      if seen.contains(child.id) {
        throw WuhuStoreError.sessionCorrupt("Cycle detected at entry \(child.id)")
      }
      ordered.append(child)
      seen.insert(child.id)
      current = child
    }

    guard current.id == tailEntryID else {
      throw WuhuStoreError.sessionCorrupt("tailEntryID=\(tailEntryID) does not match last.id=\(current.id)")
    }

    if ordered.count != entries.count {
      throw WuhuStoreError.sessionCorrupt("Entries are not a single linear chain (expected \(entries.count), got \(ordered.count))")
    }

    return ordered
  }
}

private struct EnvironmentRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "environments"

  var id: String
  var name: String
  var type: String
  var path: String
  var templatePath: String?
  var startupScript: String?
  var createdAt: Date
  var updatedAt: Date

  func toModel() throws -> WuhuEnvironmentDefinition {
    guard let envType = WuhuEnvironmentType(rawValue: type) else {
      throw WuhuEnvironmentResolutionError.unsupportedEnvironmentType(type)
    }
    return .init(
      id: id,
      name: name,
      type: envType,
      path: path,
      templatePath: templatePath,
      startupScript: startupScript,
      createdAt: createdAt,
      updatedAt: updatedAt,
    )
  }
}

private struct SessionRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "sessions"

  var id: String
  var sessionType: String
  var provider: String
  var model: String
  var effectiveReasoningEffort: String?
  var pendingProvider: String?
  var pendingModel: String?
  var pendingReasoningEffort: String?
  var executionStatus: String
  var environmentID: String?
  var environmentName: String
  var environmentType: String
  var environmentPath: String
  var environmentTemplatePath: String?
  var environmentStartupScript: String?
  var cwd: String
  var runnerName: String?
  var parentSessionID: String?
  var displayStartEntryID: Int64?
  var createdAt: Date
  var updatedAt: Date
  var headEntryID: Int64?
  var tailEntryID: Int64?

  func toModel() throws -> WuhuSession {
    guard let provider = WuhuProvider(rawValue: provider) else {
      throw WuhuStoreError.sessionCorrupt("Unknown provider: \(self.provider)")
    }
    let type = WuhuSessionType(rawValue: sessionType) ?? .coding
    guard let headEntryID, let tailEntryID else {
      throw WuhuStoreError.sessionCorrupt("Session \(id) missing head/tail entry ids")
    }
    guard let envType = WuhuEnvironmentType(rawValue: environmentType) else {
      throw WuhuStoreError.sessionCorrupt("Unknown environment type: \(environmentType)")
    }
    return .init(
      id: id,
      type: type,
      provider: provider,
      model: model,
      environmentID: environmentID,
      environment: .init(
        name: environmentName,
        type: envType,
        path: environmentPath,
        templatePath: environmentTemplatePath,
        startupScript: environmentStartupScript,
      ),
      cwd: cwd,
      runnerName: runnerName,
      parentSessionID: parentSessionID,
      displayStartEntryID: displayStartEntryID,
      createdAt: createdAt,
      updatedAt: updatedAt,
      headEntryID: headEntryID,
      tailEntryID: tailEntryID,
    )
  }
}

private struct EntryRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "session_entries"

  var id: Int64?
  var sessionID: String
  var parentEntryID: Int64?
  var type: String
  var payload: Data
  var createdAt: Date

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  static func new(
    sessionID: String,
    parentEntryID: Int64?,
    payload: WuhuEntryPayload,
    createdAt: Date,
  ) throws -> EntryRow {
    let encoded = try WuhuJSON.encoder.encode(payload)
    return .init(
      id: nil,
      sessionID: sessionID,
      parentEntryID: parentEntryID,
      type: payload.typeString,
      payload: encoded,
      createdAt: createdAt,
    )
  }

  func toModel() -> WuhuSessionEntry {
    let decoded: WuhuEntryPayload = Self.decodePayload(type: type, data: payload)
    return .init(
      id: id ?? -1,
      sessionID: sessionID,
      parentEntryID: parentEntryID,
      createdAt: createdAt,
      payload: decoded,
    )
  }

  private static func decodePayload(type: String, data: Data) -> WuhuEntryPayload {
    if let payload = try? WuhuJSON.decoder.decode(WuhuEntryPayload.self, from: data) {
      return payload
    }
    if let json = try? WuhuJSON.decoder.decode(JSONValue.self, from: data) {
      return .unknown(type: type, payload: json)
    }
    return .unknown(type: type, payload: .null)
  }
}

extension SQLiteSessionStore {
  private static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("wuhu_contracts_v1") { db in
      // Hard reset: this repo intentionally does not migrate older schemas.
      try db.execute(sql: "DROP TABLE IF EXISTS tool_call_status")
      try db.execute(sql: "DROP TABLE IF EXISTS system_queue_pending")
      try db.execute(sql: "DROP TABLE IF EXISTS system_queue_journal")
      try db.execute(sql: "DROP TABLE IF EXISTS user_queue_pending")
      try db.execute(sql: "DROP TABLE IF EXISTS user_queue_journal")
      try db.execute(sql: "DROP TABLE IF EXISTS session_entries")
      try db.execute(sql: "DROP TABLE IF EXISTS session_child_status")
      try db.execute(sql: "DROP TABLE IF EXISTS sessions")
      try db.execute(sql: "DROP TABLE IF EXISTS environments")

      try db.create(table: "sessions") { t in
        t.column("id", .text).primaryKey()
        t.column("provider", .text).notNull()
        t.column("model", .text).notNull()
        t.column("effectiveReasoningEffort", .text)
        t.column("pendingProvider", .text)
        t.column("pendingModel", .text)
        t.column("pendingReasoningEffort", .text)
        t.column("executionStatus", .text).notNull()
        t.column("environmentName", .text).notNull()
        t.column("environmentType", .text).notNull()
        t.column("environmentPath", .text).notNull()
        t.column("environmentTemplatePath", .text)
        t.column("environmentStartupScript", .text)
        t.column("cwd", .text).notNull()
        t.column("runnerName", .text)
        t.column("parentSessionID", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("headEntryID", .integer)
        t.column("tailEntryID", .integer)
      }

      try db.create(table: "session_entries") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("parentEntryID", .integer).references("session_entries", onDelete: .restrict)
        t.column("type", .text).notNull().indexed()
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }

      // Enforce "no fork within session": parentEntryID can have at most one child across the table.
      // This also makes linear chain traversal O(n) and tail updates cheap.
      try db.create(index: "session_entries_unique_parent", on: "session_entries", columns: ["parentEntryID"], unique: true, condition: Column("parentEntryID") != nil)

      // Enforce exactly one header per session: the only entry with parentEntryID IS NULL.
      try db.create(index: "session_entries_unique_header_per_session", on: "session_entries", columns: ["sessionID"], unique: true, condition: Column("parentEntryID") == nil)

      try db.create(table: "tool_call_status") { t in
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("toolCallID", .text).notNull()
        t.column("status", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["sessionID", "toolCallID"])
      }

      try db.create(table: "user_queue_pending") { t in
        t.column("id", .text).primaryKey()
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lane", .text).notNull().indexed()
        t.column("enqueuedAt", .datetime).notNull().indexed()
        t.column("payload", .blob).notNull()
      }

      try db.create(table: "user_queue_journal") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lane", .text).notNull().indexed()
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }

      try db.create(table: "system_queue_pending") { t in
        t.column("id", .text).primaryKey()
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("enqueuedAt", .datetime).notNull().indexed()
        t.column("payload", .blob).notNull()
      }

      try db.create(table: "system_queue_journal") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("payload", .blob).notNull()
        t.column("createdAt", .datetime).notNull().indexed()
      }
    }

    migrator.registerMigration("wuhu_contracts_v2_environments") { db in
      try db.create(table: "environments") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("type", .text).notNull()
        t.column("path", .text).notNull()
        t.column("templatePath", .text)
        t.column("startupScript", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.create(index: "environments_unique_name", on: "environments", columns: ["name"], unique: true)

      try db.alter(table: "sessions") { t in
        t.add(column: "environmentID", .text)
      }
    }

    migrator.registerMigration("wuhu_contracts_v3_channels") { db in
      try db.alter(table: "sessions") { t in
        t.add(column: "sessionType", .text).notNull().defaults(to: WuhuSessionType.coding.rawValue)
        t.add(column: "displayStartEntryID", .integer)
      }

      try db.create(table: "session_child_status") { t in
        t.column("parentSessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("childSessionID", .text).notNull().indexed().references("sessions", onDelete: .cascade)
        t.column("lastNotifiedFinalEntryID", .integer)
        t.column("lastReadFinalEntryID", .integer)
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["parentSessionID", "childSessionID"])
      }
    }

    return migrator
  }()
}

// MARK: - Contracts State (Queues / Tool Calls / Settings)

extension SQLiteSessionStore {
  struct LoopStateParts: Sendable {
    var session: WuhuSession
    var entries: [WuhuSessionEntry]
    var toolCallStatus: [String: ToolCallStatus]
    var settings: SessionSettingsSnapshot
    var status: SessionStatusSnapshot
    var systemUrgent: SystemUrgentQueueBackfill
    var steer: UserQueueBackfill
    var followUp: UserQueueBackfill
  }

  struct DrainResult: Sendable {
    var didDrain: Bool
    var session: WuhuSession
    var entries: [WuhuSessionEntry]
    var systemUrgent: SystemUrgentQueueBackfill
    var steer: UserQueueBackfill
    var followUp: UserQueueBackfill
  }

  struct ToolCallStatusUpdate: Sendable, Hashable {
    var id: String
    var status: ToolCallStatus
  }

  func loadLoopStateParts(sessionID: SessionID) async throws -> LoopStateParts {
    let session = try await getSession(id: sessionID.rawValue)
    let entries = try await getEntries(sessionID: sessionID.rawValue)
    let toolCallStatus = try await loadToolCallStatus(sessionID: sessionID)
    let settings = try await loadSettingsSnapshot(sessionID: sessionID)
    let status = try await loadStatusSnapshot(sessionID: sessionID)
    let systemUrgent = try await loadSystemQueueBackfill(sessionID: sessionID)
    let steer = try await loadUserQueueBackfill(sessionID: sessionID, lane: .steer)
    let followUp = try await loadUserQueueBackfill(sessionID: sessionID, lane: .followUp)
    return .init(
      session: session,
      entries: entries,
      toolCallStatus: toolCallStatus,
      settings: settings,
      status: status,
      systemUrgent: systemUrgent,
      steer: steer,
      followUp: followUp,
    )
  }

  func loadSettingsSnapshot(sessionID: SessionID) async throws -> SessionSettingsSnapshot {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }

      let effectiveModel = ModelSpecifier(provider: ProviderID(rawValue: row.provider), id: row.model)
      let pendingModel: ModelSpecifier? = {
        guard let p = row.pendingProvider, let m = row.pendingModel else { return nil }
        return ModelSpecifier(provider: ProviderID(rawValue: p), id: m)
      }()

      let effectiveEffort = row.effectiveReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
      let pendingEffort = row.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))

      return .init(
        effectiveModel: effectiveModel,
        pendingModel: pendingModel,
        effectiveReasoningEffort: effectiveEffort,
        pendingReasoningEffort: pendingEffort,
      )
    }
  }

  func loadStatusSnapshot(sessionID: SessionID) async throws -> SessionStatusSnapshot {
    try await dbQueue.read { db in
      guard let row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let status = SessionExecutionStatus(rawValue: row.executionStatus) ?? .idle
      return .init(status: status)
    }
  }

  func setSessionExecutionStatus(sessionID: SessionID, status: SessionExecutionStatus) async throws {
    try await dbQueue.write { db in
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: status)
    }
  }

  func setPendingModelSelection(sessionID: SessionID, selection: WuhuSessionSettings) async throws -> SessionSettingsSnapshot {
    try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      row.pendingProvider = selection.provider.rawValue
      row.pendingModel = selection.model
      row.pendingReasoningEffort = selection.reasoningEffort?.rawValue
      row.updatedAt = Date()
      try row.update(db)
    }
    return try await loadSettingsSnapshot(sessionID: sessionID)
  }

  func applyModelSelection(sessionID: SessionID, selection: WuhuSessionSettings) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot) {
    let (session, entry) = try await appendEntryWithSession(
      sessionID: sessionID,
      payload: .sessionSettings(selection),
      createdAt: Date(),
    )
    let settings = try await loadSettingsSnapshot(sessionID: sessionID)
    return (session, entry, settings)
  }

  func applyPendingModelIfPossible(sessionID: SessionID) async throws -> (session: WuhuSession, entry: WuhuSessionEntry, settings: SessionSettingsSnapshot)? {
    let result: (WuhuSession, WuhuSessionEntry)? = try await dbQueue.write { db in
      guard var row = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      guard let p = row.pendingProvider, let m = row.pendingModel else { return nil }

      // Only apply when no other work is pending.
      guard row.executionStatus == SessionExecutionStatus.idle.rawValue else { return nil }
      guard try Self.pendingWorkCount(db: db, sessionID: sessionID.rawValue) == 0 else { return nil }

      let provider = WuhuProvider(rawValue: p) ?? .openai
      let selection = WuhuSessionSettings(provider: provider, model: m, reasoningEffort: row.pendingReasoningEffort.flatMap(ReasoningEffort.init(rawValue:)))

      // Append a settings entry; `appendEntryWithSession` will clear pending.
      let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &row, payload: .sessionSettings(selection), createdAt: Date())
      return try (row.toModel(), entryRow.toModel())
    }

    guard let result else { return nil }
    return try await (result.0, result.1, loadSettingsSnapshot(sessionID: sessionID))
  }

  func enqueueUserMessage(sessionID: SessionID, id: QueueItemID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    let now = Date()
    try await dbQueue.write { db in
      let data = try WuhuJSON.encoder.encode(message)
      try db.execute(
        sql: """
        INSERT INTO user_queue_pending (id, sessionID, lane, enqueuedAt, payload)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [id.rawValue, sessionID.rawValue, lane.rawValue, now, data],
      )

      let pendingItem = UserQueuePendingItem(id: id, enqueuedAt: now, message: message)
      let journal = UserQueueJournalEntry.enqueued(lane: lane, item: pendingItem)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: """
        INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt)
        VALUES (?, ?, ?, ?)
        """,
        arguments: [sessionID.rawValue, lane.rawValue, journalData, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
    }
    return id
  }

  func cancelUserMessage(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws {
    let now = Date()
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
        arguments: [sessionID.rawValue, lane.rawValue, id.rawValue],
      )
      if db.changesCount == 0 {
        throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
      }

      let journal = UserQueueJournalEntry.canceled(lane: lane, id: id, at: now)
      let data = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
        arguments: [sessionID.rawValue, lane.rawValue, data, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionID.rawValue)
    }
  }

  func enqueueSystemInput(sessionID: SessionID, id: QueueItemID, input: SystemUrgentInput, enqueuedAt: Date) async throws -> QueueItemID {
    let now = enqueuedAt
    try await dbQueue.write { db in
      let data = try WuhuJSON.encoder.encode(input)
      try db.execute(
        sql: "INSERT INTO system_queue_pending (id, sessionID, enqueuedAt, payload) VALUES (?, ?, ?, ?)",
        arguments: [id.rawValue, sessionID.rawValue, now, data],
      )

      let pendingItem = SystemUrgentPendingItem(id: id, enqueuedAt: now, input: input)
      let journal = SystemUrgentQueueJournalEntry.enqueued(item: pendingItem)
      let journalData = try WuhuJSON.encoder.encode(journal)
      try db.execute(
        sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
        arguments: [sessionID.rawValue, journalData, now],
      )

      try Self.updateSessionUpdatedAt(db: db, sessionID: sessionID.rawValue)
      try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
    }
    return id
  }

  func drainInterruptCheckpoint(sessionID: SessionID) async throws -> DrainResult {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }

      let systemRows = try SystemQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue)
        .fetchAll(db)
      let steerRows = try UserQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == UserQueueLane.steer.rawValue)
        .fetchAll(db)

      struct Candidate {
        var enqueuedAt: Date
        var kind: String
        var id: String
        var payload: Data
      }

      var candidates: [Candidate] = []
      candidates.reserveCapacity(systemRows.count + steerRows.count)
      for r in systemRows {
        candidates.append(.init(enqueuedAt: r.enqueuedAt, kind: "system", id: r.id, payload: r.payload))
      }
      for r in steerRows {
        candidates.append(.init(enqueuedAt: r.enqueuedAt, kind: "steer", id: r.id, payload: r.payload))
      }
      candidates.sort { a, b in
        if a.enqueuedAt != b.enqueuedAt { return a.enqueuedAt < b.enqueuedAt }
        return a.id < b.id
      }

      guard !candidates.isEmpty else {
        let session = try sessionRow.toModel()
        return try DrainResult(
          didDrain: false,
          session: session,
          entries: [],
          systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
          steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
          followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
        )
      }

      var appended: [WuhuSessionEntry] = []
      appended.reserveCapacity(candidates.count)

      for c in candidates {
        let entryPayload: WuhuEntryPayload
        let createdAt = c.enqueuedAt

        if c.kind == "system" {
          let input = try WuhuJSON.decoder.decode(SystemUrgentInput.self, from: c.payload)
          let text: String = {
            if case let .text(t) = input.content { return t }
            return ""
          }()
          let custom = WuhuCustomMessage(
            customType: "wuhu_system_input_v1",
            content: [.text(text: text, signature: nil)],
            details: .object([
              "source": .string(systemSourceString(input.source)),
            ]),
            display: true,
            timestamp: createdAt,
          )
          entryPayload = .message(.customMessage(custom))

          try db.execute(
            sql: "DELETE FROM system_queue_pending WHERE sessionID = ? AND id = ?",
            arguments: [sessionID.rawValue, c.id],
          )
        } else {
          let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: c.payload)
          let text: String = {
            if case let .text(t) = message.content { return t }
            return ""
          }()
          let user = WuhuUserMessage(
            user: userString(message.author),
            content: [.text(text: text, signature: nil)],
            timestamp: createdAt,
          )
          entryPayload = .message(.user(user))

          try db.execute(
            sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
            arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, c.id],
          )
        }

        let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: entryPayload, createdAt: createdAt)
        appended.append(entryRow.toModel())

        let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
        let now = Date()

        if c.kind == "system" {
          let journal = SystemUrgentQueueJournalEntry.materialized(
            id: QueueItemID(rawValue: c.id),
            transcriptEntryID: transcriptEntryID,
            at: now,
          )
          let data = try WuhuJSON.encoder.encode(journal)
          try db.execute(
            sql: "INSERT INTO system_queue_journal (sessionID, payload, createdAt) VALUES (?, ?, ?)",
            arguments: [sessionID.rawValue, data, now],
          )
        } else {
          let journal = UserQueueJournalEntry.materialized(
            lane: .steer,
            id: QueueItemID(rawValue: c.id),
            transcriptEntryID: transcriptEntryID,
            at: now,
          )
          let data = try WuhuJSON.encoder.encode(journal)
          try db.execute(
            sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
            arguments: [sessionID.rawValue, UserQueueLane.steer.rawValue, data, now],
          )
        }
      }

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: true,
        session: session,
        entries: appended,
        systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
        steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
        followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
      )
    }
  }

  func drainTurnBoundary(sessionID: SessionID) async throws -> DrainResult {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }

      let followRows = try UserQueuePendingRow
        .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == UserQueueLane.followUp.rawValue)
        .order(Column("enqueuedAt").asc)
        .fetchAll(db)

      guard !followRows.isEmpty else {
        let session = try sessionRow.toModel()
        return try DrainResult(
          didDrain: false,
          session: session,
          entries: [],
          systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
          steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
          followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
        )
      }

      var appended: [WuhuSessionEntry] = []
      appended.reserveCapacity(followRows.count)

      for r in followRows {
        let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: r.payload)
        let text: String = {
          if case let .text(t) = message.content { return t }
          return ""
        }()

        let user = WuhuUserMessage(
          user: userString(message.author),
          content: [.text(text: text, signature: nil)],
          timestamp: r.enqueuedAt,
        )

        let entryPayload: WuhuEntryPayload = .message(.user(user))
        let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: entryPayload, createdAt: r.enqueuedAt)
        appended.append(entryRow.toModel())

        try db.execute(
          sql: "DELETE FROM user_queue_pending WHERE sessionID = ? AND lane = ? AND id = ?",
          arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, r.id],
        )

        let transcriptEntryID = TranscriptEntryID(rawValue: "\(entryRow.id ?? -1)")
        let journal = UserQueueJournalEntry.materialized(
          lane: .followUp,
          id: QueueItemID(rawValue: r.id),
          transcriptEntryID: transcriptEntryID,
          at: Date(),
        )
        let data = try WuhuJSON.encoder.encode(journal)
        try db.execute(
          sql: "INSERT INTO user_queue_journal (sessionID, lane, payload, createdAt) VALUES (?, ?, ?, ?)",
          arguments: [sessionID.rawValue, UserQueueLane.followUp.rawValue, data, Date()],
        )
      }

      let session = try sessionRow.toModel()
      return try DrainResult(
        didDrain: true,
        session: session,
        entries: appended,
        systemUrgent: Self.loadSystemQueueBackfill(db: db, sessionID: sessionID),
        steer: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .steer),
        followUp: Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: .followUp),
      )
    }
  }

  func loadSystemQueueBackfill(sessionID: SessionID) async throws -> SystemUrgentQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadSystemQueueBackfill(db: db, sessionID: sessionID)
    }
  }

  func loadUserQueueBackfill(sessionID: SessionID, lane: UserQueueLane) async throws -> UserQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane)
    }
  }

  func loadSystemQueueBackfill(sessionID: SessionID, since cursor: QueueCursor?) async throws -> SystemUrgentQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadSystemQueueBackfill(db: db, sessionID: sessionID, since: cursor)
    }
  }

  func loadUserQueueBackfill(sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor?) async throws -> UserQueueBackfill {
    try await dbQueue.read { db in
      try Self.loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane, since: cursor)
    }
  }

  func loadSystemQueueJournal(sessionID: SessionID, since cursor: QueueCursor) async throws -> (cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry]) {
    try await dbQueue.read { db in
      try Self.loadSystemQueueJournal(db: db, sessionID: sessionID, since: cursor)
    }
  }

  func loadUserQueueJournal(sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor) async throws -> (cursor: QueueCursor, entries: [UserQueueJournalEntry]) {
    try await dbQueue.read { db in
      try Self.loadUserQueueJournal(db: db, sessionID: sessionID, lane: lane, since: cursor)
    }
  }

  func loadToolCallStatus(sessionID: SessionID) async throws -> [String: ToolCallStatus] {
    try await dbQueue.read { db in
      let rows = try ToolCallStatusRow
        .filter(Column("sessionID") == sessionID.rawValue)
        .fetchAll(db)
      var out: [String: ToolCallStatus] = [:]
      out.reserveCapacity(rows.count)
      for r in rows {
        out[r.toolCallID] = ToolCallStatus(rawValue: r.status) ?? .pending
      }
      return out
    }
  }

  func upsertToolCallStatuses(sessionID: SessionID, calls: [ToolCall], status: ToolCallStatus) async throws -> [ToolCallStatusUpdate] {
    let now = Date()
    try await dbQueue.write { db in
      for call in calls {
        try db.execute(
          sql: """
          INSERT INTO tool_call_status (sessionID, toolCallID, status, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(sessionID, toolCallID) DO UPDATE SET status = excluded.status, updatedAt = excluded.updatedAt
          """,
          arguments: [sessionID.rawValue, call.id, status.rawValue, now, now],
        )
      }
      if status == .pending || status == .started {
        try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
      }
    }
    return calls.map { .init(id: $0.id, status: status) }
  }

  func setToolCallStatus(sessionID: SessionID, id: String, status: ToolCallStatus) async throws -> ToolCallStatusUpdate {
    let now = Date()
    try await dbQueue.write { db in
      try db.execute(
        sql: """
        INSERT INTO tool_call_status (sessionID, toolCallID, status, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(sessionID, toolCallID) DO UPDATE SET status = excluded.status, updatedAt = excluded.updatedAt
        """,
        arguments: [sessionID.rawValue, id, status.rawValue, now, now],
      )
      if status == .pending || status == .started {
        try Self.setExecutionStatus(db: db, sessionID: sessionID.rawValue, status: .running)
      }
    }
    return .init(id: id, status: status)
  }

  func appendEntryWithSession(sessionID: SessionID, payload: WuhuEntryPayload, createdAt: Date) async throws -> (WuhuSession, WuhuSessionEntry) {
    try await dbQueue.write { db in
      guard var sessionRow = try SessionRow.fetchOne(db, key: sessionID.rawValue) else {
        throw WuhuStoreError.sessionNotFound(sessionID.rawValue)
      }
      let entryRow = try Self.appendEntryWithSession(db: db, sessionRow: &sessionRow, payload: payload, createdAt: createdAt)
      return try (sessionRow.toModel(), entryRow.toModel())
    }
  }

  // MARK: - Helpers (DB)

  private static func updateSessionUpdatedAt(db: Database, sessionID: String) throws {
    try db.execute(
      sql: "UPDATE sessions SET updatedAt = ? WHERE id = ?",
      arguments: [Date(), sessionID],
    )
  }

  private static func setExecutionStatus(db: Database, sessionID: String, status: SessionExecutionStatus) throws {
    try db.execute(
      sql: "UPDATE sessions SET executionStatus = ?, updatedAt = ? WHERE id = ?",
      arguments: [status.rawValue, Date(), sessionID],
    )
  }

  private static func maybeSetIdleIfNoPendingWork(db: Database, sessionID: String) throws {
    guard let row = try SessionRow.fetchOne(db, key: sessionID) else {
      throw WuhuStoreError.sessionNotFound(sessionID)
    }
    if row.executionStatus == SessionExecutionStatus.stopped.rawValue {
      return
    }
    let pending = try pendingWorkCount(db: db, sessionID: sessionID)
    if pending == 0 {
      try setExecutionStatus(db: db, sessionID: sessionID, status: .idle)
    }
  }

  private static func pendingWorkCount(db: Database, sessionID: String) throws -> Int {
    let systemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM system_queue_pending WHERE sessionID = ?", arguments: [sessionID]) ?? 0
    let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_queue_pending WHERE sessionID = ?", arguments: [sessionID]) ?? 0
    let toolCount = try Int.fetchOne(
      db,
      sql: """
      SELECT COUNT(*) FROM tool_call_status
      WHERE sessionID = ? AND (status = ? OR status = ?)
      """,
      arguments: [sessionID, ToolCallStatus.pending.rawValue, ToolCallStatus.started.rawValue],
    ) ?? 0
    return systemCount + userCount + toolCount
  }

  private static func loadSystemQueueBackfill(db: Database, sessionID: SessionID) throws -> SystemUrgentQueueBackfill {
    try loadSystemQueueBackfill(db: db, sessionID: sessionID, since: nil)
  }

  private static func loadSystemQueueBackfill(db: Database, sessionID: SessionID, since cursor: QueueCursor?) throws -> SystemUrgentQueueBackfill {
    let pendingRows = try SystemQueuePendingRow
      .filter(Column("sessionID") == sessionID.rawValue)
      .order(Column("enqueuedAt").asc)
      .fetchAll(db)
    let pending: [SystemUrgentPendingItem] = try pendingRows.map { row in
      let input = try WuhuJSON.decoder.decode(SystemUrgentInput.self, from: row.payload)
      return .init(id: QueueItemID(rawValue: row.id), enqueuedAt: row.enqueuedAt, input: input)
    }

    let sinceID = Int64(cursor?.rawValue ?? "") ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM system_queue_journal WHERE sessionID = ?",
      arguments: [sessionID.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try SystemQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let journal: [SystemUrgentQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(SystemUrgentQueueJournalEntry.self, from: row.payload)
    }

    return .init(cursor: .init(rawValue: "\(effectiveMax)"), pending: pending, journal: journal)
  }

  private static func loadSystemQueueJournal(
    db: Database,
    sessionID: SessionID,
    since cursor: QueueCursor,
  ) throws -> (cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry]) {
    let sinceID = Int64(cursor.rawValue) ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM system_queue_journal WHERE sessionID = ?",
      arguments: [sessionID.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try SystemQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let entries: [SystemUrgentQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(SystemUrgentQueueJournalEntry.self, from: row.payload)
    }

    return (cursor: .init(rawValue: "\(effectiveMax)"), entries: entries)
  }

  private static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane) throws -> UserQueueBackfill {
    try loadUserQueueBackfill(db: db, sessionID: sessionID, lane: lane, since: nil)
  }

  private static func loadUserQueueBackfill(db: Database, sessionID: SessionID, lane: UserQueueLane, since cursor: QueueCursor?) throws -> UserQueueBackfill {
    let pendingRows = try UserQueuePendingRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue)
      .order(Column("enqueuedAt").asc)
      .fetchAll(db)
    let pending: [UserQueuePendingItem] = try pendingRows.map { row in
      let message = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: row.payload)
      return .init(id: QueueItemID(rawValue: row.id), enqueuedAt: row.enqueuedAt, message: message)
    }

    let sinceID = Int64(cursor?.rawValue ?? "") ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM user_queue_journal WHERE sessionID = ? AND lane = ?",
      arguments: [sessionID.rawValue, lane.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try UserQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let journal: [UserQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(UserQueueJournalEntry.self, from: row.payload)
    }

    return .init(cursor: .init(rawValue: "\(effectiveMax)"), pending: pending, journal: journal)
  }

  private static func loadUserQueueJournal(
    db: Database,
    sessionID: SessionID,
    lane: UserQueueLane,
    since cursor: QueueCursor,
  ) throws -> (cursor: QueueCursor, entries: [UserQueueJournalEntry]) {
    let sinceID = Int64(cursor.rawValue) ?? 0
    let maxID = try Int64.fetchOne(
      db,
      sql: "SELECT MAX(id) FROM user_queue_journal WHERE sessionID = ? AND lane = ?",
      arguments: [sessionID.rawValue, lane.rawValue],
    ) ?? 0
    let effectiveMax = max(maxID, sinceID)

    let journalRows = try UserQueueJournalRow
      .filter(Column("sessionID") == sessionID.rawValue && Column("lane") == lane.rawValue && Column("id") > sinceID)
      .order(Column("id").asc)
      .fetchAll(db)
    let entries: [UserQueueJournalEntry] = try journalRows.map { row in
      try WuhuJSON.decoder.decode(UserQueueJournalEntry.self, from: row.payload)
    }

    return (cursor: .init(rawValue: "\(effectiveMax)"), entries: entries)
  }

  private static func appendEntryWithSession(db: Database, sessionRow: inout SessionRow, payload: WuhuEntryPayload, createdAt: Date) throws -> EntryRow {
    let tailID = sessionRow.tailEntryID

    var row = try EntryRow.new(
      sessionID: sessionRow.id,
      parentEntryID: tailID,
      payload: payload,
      createdAt: createdAt,
    )
    try row.insert(db)
    guard let newID = row.id else {
      throw WuhuStoreError.sessionCorrupt("Failed to create entry id")
    }

    sessionRow.tailEntryID = newID
    sessionRow.updatedAt = Date()

    if case let .sessionSettings(settings) = payload {
      sessionRow.provider = settings.provider.rawValue
      sessionRow.model = settings.model
      sessionRow.effectiveReasoningEffort = settings.reasoningEffort?.rawValue
      sessionRow.pendingProvider = nil
      sessionRow.pendingModel = nil
      sessionRow.pendingReasoningEffort = nil
    }

    try sessionRow.update(db)

    if case let .message(message) = payload,
       case let .assistant(assistant) = message
    {
      let hasToolCalls = assistant.content.contains { block in
        if case .toolCall = block { return true }
        return false
      }
      if hasToolCalls {
        try setExecutionStatus(db: db, sessionID: sessionRow.id, status: .running)
      } else {
        try maybeSetIdleIfNoPendingWork(db: db, sessionID: sessionRow.id)
      }
    }

    guard let fetched = try EntryRow.fetchOne(db, key: newID) else {
      throw WuhuStoreError.sessionCorrupt("Failed to re-fetch inserted entry \(newID)")
    }
    return fetched
  }
}

private struct ToolCallStatusRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "tool_call_status"
  var sessionID: String
  var toolCallID: String
  var status: String
  var createdAt: Date
  var updatedAt: Date
}

private struct SessionChildStatusRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "session_child_status"
  var parentSessionID: String
  var childSessionID: String
  var lastNotifiedFinalEntryID: Int64?
  var lastReadFinalEntryID: Int64?
  var updatedAt: Date
}

private struct UserQueuePendingRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "user_queue_pending"
  var id: String
  var sessionID: String
  var lane: String
  var enqueuedAt: Date
  var payload: Data
}

private struct UserQueueJournalRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "user_queue_journal"
  var id: Int64
  var sessionID: String
  var lane: String
  var payload: Data
  var createdAt: Date
}

private struct SystemQueuePendingRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "system_queue_pending"
  var id: String
  var sessionID: String
  var enqueuedAt: Date
  var payload: Data
}

private struct SystemQueueJournalRow: Codable, FetchableRecord, TableRecord {
  static let databaseTableName = "system_queue_journal"
  var id: Int64
  var sessionID: String
  var payload: Data
  var createdAt: Date
}

private func userString(_ author: Author) -> String {
  switch author {
  case .system:
    "system"
  case let .participant(id, _):
    id.rawValue
  case .unknown:
    WuhuUserMessage.unknownUser
  }
}

private func systemSourceString(_ source: SystemUrgentSource) -> String {
  switch source {
  case .asyncBashCallback:
    "asyncBashCallback"
  case .asyncTaskNotification:
    "asyncTaskNotification"
  case let .other(s):
    s
  }
}
