import Foundation
import GRDB
import WuhuAPI

public protocol RunnerStore: Sendable {
  func upsertSession(sessionID: String, environment: WuhuEnvironment) async throws
  func getEnvironment(sessionID: String) async throws -> WuhuEnvironment?
}

public actor SQLiteRunnerStore: RunnerStore {
  private let dbQueue: DatabaseQueue

  public init(path: String) throws {
    var config = Configuration()
    config.busyMode = .timeout(5)
    dbQueue = try DatabaseQueue(path: path, configuration: config)
    try Self.migrator.migrate(dbQueue)
  }

  public func upsertSession(sessionID: String, environment: WuhuEnvironment) async throws {
    let now = Date()
    try await dbQueue.write { db in
      var row = RunnerSessionRow(
        sessionID: sessionID,
        environmentName: environment.name,
        environmentType: environment.type.rawValue,
        environmentPath: environment.path,
        environmentTemplatePath: environment.templatePath,
        environmentStartupScript: environment.startupScript,
        createdAt: now,
        updatedAt: now,
      )
      try row.save(db)
    }
  }

  public func getEnvironment(sessionID: String) async throws -> WuhuEnvironment? {
    try await dbQueue.read { db in
      guard let row = try RunnerSessionRow.fetchOne(db, key: sessionID) else { return nil }
      guard let type = WuhuEnvironmentType(rawValue: row.environmentType) else { return nil }
      return .init(
        name: row.environmentName,
        type: type,
        path: row.environmentPath,
        templatePath: row.environmentTemplatePath,
        startupScript: row.environmentStartupScript,
      )
    }
  }
}

private struct RunnerSessionRow: Codable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "runner_sessions"

  var sessionID: String
  var environmentName: String
  var environmentType: String
  var environmentPath: String
  var environmentTemplatePath: String?
  var environmentStartupScript: String?
  var createdAt: Date
  var updatedAt: Date
}

extension SQLiteRunnerStore {
  private static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("createRunnerSessions_v1") { db in
      try db.create(table: "runner_sessions") { t in
        t.column("sessionID", .text).primaryKey()
        t.column("environmentName", .text).notNull()
        t.column("environmentType", .text).notNull()
        t.column("environmentPath", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration("environmentMetadata_v2") { db in
      let info = try Row.fetchAll(db, sql: "PRAGMA table_info(runner_sessions)")
      let existing = Set(info.compactMap { $0["name"] as String? })
      let needsTemplate = !existing.contains("environmentTemplatePath")
      let needsStartup = !existing.contains("environmentStartupScript")
      guard needsTemplate || needsStartup else { return }

      try db.alter(table: "runner_sessions") { t in
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
