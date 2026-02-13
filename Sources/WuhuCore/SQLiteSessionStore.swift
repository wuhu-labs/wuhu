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

  public func createSession(
    sessionID rawSessionID: String,
    provider: WuhuProvider,
    model: String,
    reasoningEffort: ReasoningEffort?,
    systemPrompt: String,
    environment: WuhuEnvironment,
    runnerName: String?,
    parentSessionID: String?,
  ) async throws -> WuhuSession {
    let now = Date()
    let sessionID = rawSessionID.lowercased()

    return try await dbQueue.write { db in
      var sessionRow = SessionRow(
        id: sessionID,
        provider: provider.rawValue,
        model: model,
        environmentName: environment.name,
        environmentType: environment.type.rawValue,
        environmentPath: environment.path,
        environmentTemplatePath: environment.templatePath,
        environmentStartupScript: environment.startupScript,
        cwd: environment.path,
        runnerName: runnerName,
        parentSessionID: parentSessionID,
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
      let headerPayload = WuhuEntryPayload.header(.init(
        systemPrompt: systemPrompt,
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

  @discardableResult
  public func appendEntry(sessionID: String, payload: WuhuEntryPayload) async throws -> WuhuSessionEntry {
    let now = Date()
    return try await dbQueue.write { db in
      guard var session = try SessionRow.fetchOne(db, key: sessionID) else {
        throw WuhuStoreError.sessionNotFound(sessionID)
      }
      guard let tailID = session.tailEntryID else {
        throw WuhuStoreError.sessionCorrupt("Session \(sessionID) missing tailEntryID")
      }

      var row = try EntryRow.new(
        sessionID: sessionID,
        parentEntryID: tailID,
        payload: payload,
        createdAt: now,
      )
      try row.insert(db)
      guard let newID = row.id else {
        throw WuhuStoreError.sessionCorrupt("Failed to create entry id")
      }

      session.tailEntryID = newID
      session.updatedAt = now

      if case let .sessionSettings(settings) = payload {
        session.provider = settings.provider.rawValue
        session.model = settings.model
      }
      try session.update(db)

      return row.toModel()
    }
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

private struct SessionRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "sessions"

  var id: String
  var provider: String
  var model: String
  var environmentName: String
  var environmentType: String
  var environmentPath: String
  var environmentTemplatePath: String?
  var environmentStartupScript: String?
  var cwd: String
  var runnerName: String?
  var parentSessionID: String?
  var createdAt: Date
  var updatedAt: Date
  var headEntryID: Int64?
  var tailEntryID: Int64?

  func toModel() throws -> WuhuSession {
    guard let provider = WuhuProvider(rawValue: provider) else {
      throw WuhuStoreError.sessionCorrupt("Unknown provider: \(self.provider)")
    }
    guard let headEntryID, let tailEntryID else {
      throw WuhuStoreError.sessionCorrupt("Session \(id) missing head/tail entry ids")
    }
    guard let envType = WuhuEnvironmentType(rawValue: environmentType) else {
      throw WuhuStoreError.sessionCorrupt("Unknown environment type: \(environmentType)")
    }
    return .init(
      id: id,
      provider: provider,
      model: model,
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

    migrator.registerMigration("createSessionsAndEntries_v1") { db in
      try db.create(table: "sessions") { t in
        t.column("id", .text).primaryKey()
        t.column("provider", .text).notNull()
        t.column("model", .text).notNull()
        t.column("environmentName", .text).notNull()
        t.column("environmentType", .text).notNull()
        t.column("environmentPath", .text).notNull()
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
    }

    migrator.registerMigration("environmentMetadata_v2") { db in
      // Older databases created before issue #25 may not have these columns.
      let info = try Row.fetchAll(db, sql: "PRAGMA table_info(sessions)")
      let existing = Set(info.compactMap { $0["name"] as String? })
      let needsTemplate = !existing.contains("environmentTemplatePath")
      let needsStartup = !existing.contains("environmentStartupScript")
      guard needsTemplate || needsStartup else { return }

      try db.alter(table: "sessions") { t in
        if needsTemplate {
          t.add(column: "environmentTemplatePath", .text)
        }
        if needsStartup {
          t.add(column: "environmentStartupScript", .text)
        }
      }
    }

    return migrator
  }()
}
