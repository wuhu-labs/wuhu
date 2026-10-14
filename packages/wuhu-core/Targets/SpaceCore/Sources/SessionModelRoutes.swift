import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

let sessionModelRouteSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_model_routes" (
  "session_id" TEXT NOT NULL PRIMARY KEY REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "grp" TEXT NOT NULL,
  "group_id" TEXT,
  "member_id" TEXT,
  "provider" TEXT NOT NULL,
  "model" TEXT NOT NULL,
  "route_epoch" TEXT NOT NULL,
  "phase" TEXT NOT NULL,
  "payload" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "session_model_route_history" (
  "decision_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "route_epoch" TEXT NOT NULL,
  "grp" TEXT NOT NULL,
  "group_id" TEXT,
  "member_id" TEXT,
  "provider" TEXT NOT NULL,
  "model" TEXT NOT NULL,
  "reason" TEXT NOT NULL,
  "placed_at" TEXT NOT NULL,
  "payload" TEXT NOT NULL,
  UNIQUE ("session_id", "route_epoch")
);
"""

@Table("session_model_routes")
struct SessionModelRouteRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("grp") var group: String
  @Column("group_id") var groupID: String?
  @Column("member_id") var memberID: String?
  @Column("provider") var provider: String
  @Column("model") var model: String
  @Column("route_epoch") var routeEpoch: String
  @Column("phase") var phase: String
  @Column("payload") var payload: String
}

@Table("session_model_route_history")
struct SessionModelRouteHistoryRow {
  @Column("decision_id", primaryKey: true) var decisionID: Int64? = nil
  @Column("session_id") var sessionID: String
  @Column("route_epoch") var routeEpoch: String
  @Column("grp") var group: String
  @Column("group_id") var groupID: String?
  @Column("member_id") var memberID: String?
  @Column("provider") var provider: String
  @Column("model") var model: String
  @Column("reason") var reason: String
  @Column("placed_at") var placedAt: String
  @Column("payload") var payload: String
}

extension SessionStore {
  public func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? {
    let key = id.rawValue
    return try await writer.read { db in
      guard let row = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db) else { return nil }
      let route = try Sessions.decode(SessionModelRoute.self, from: row.payload)
      let stored = try Sessions.storedExecutor(key, in: db)
      if route.group == nil, stored != .kernel(route.specifier) { return nil }
      guard route.group == nil || stored == .kernel(route.specifier) else {
        throw SessionStoreError.modelRouteInvalid(group: route.group!, member: route.member ?? "<missing>")
      }
      return route
    }
  }

  public func modelRouteHistory(_ id: SessionID) async throws -> [SessionModelRoute] {
    let key = id.rawValue
    return try await writer.read { db in
      try SessionModelRouteHistoryRow.where { $0.sessionID.eq(key) }.order { $0.decisionID }.fetchAll(db)
        .map { try Sessions.decode(SessionModelRoute.self, from: $0.payload) }
    }
  }

  public func establishModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute {
    let key = id.rawValue
    return try await writer.write { db in
      if let row = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db) {
        let held = try Sessions.decode(SessionModelRoute.self, from: row.payload)
        if held.group != nil || route.group != nil || (held.specifier == route.specifier && held.bindingFingerprint == route.bindingFingerprint) {
          return held
        }
      }
      try Sessions.writeModelRoute(key, route: route, in: db)
      return route
    }
  }
}

extension Sessions {
  static func concreteExecutor(_ executor: SessionExecutor, route: SessionModelRoute?) throws -> SessionExecutor {
    if case let .modelGroup(group, effort) = executor {
      guard let route, route.group == group, route.member != nil, route.specifier.effort == effort else {
        throw ExecutorSpecError("a model group requires a matching prepared placement")
      }
      return .kernel(route.specifier)
    }
    guard route?.group == nil else { throw ExecutorSpecError("a direct target cannot carry group intent") }
    return executor
  }

  static func storedExecutor(_ key: String, in db: Database) throws -> SessionExecutor {
    guard let row = try Row.fetchOne(db, sql: "SELECT executor, executor_config FROM sessions WHERE id = ?", arguments: [key]) else {
      throw SessionStoreError.unknownSession(key)
    }
    return try SessionExecutor(kind: row["executor"], configJSON: row["executor_config"])
  }

  static func writeModelRoute(_ key: String, route: SessionModelRoute?, in db: Database) throws {
    try SessionModelRouteRow.where { $0.sessionID.eq(key) }.delete().execute(db)
    guard let route else { return }
    guard try storedExecutor(key, in: db) == .kernel(route.specifier), (route.group == nil) == (route.member == nil) else {
      throw ExecutorSpecError("route must match the stored concrete target")
    }
    let group = try group(of: key, in: db).rawValue
    let payload = try encode(route)
    let row = SessionModelRouteRow(
      sessionID: key,
      group: group,
      groupID: route.group,
      memberID: route.member,
      provider: route.specifier.provider,
      model: route.specifier.model,
      routeEpoch: route.epoch,
      phase: route.group == nil ? "bound" : "pinned",
      payload: payload,
    )
    try SessionModelRouteRow.insert { row }.execute(db)
    let decision = SessionModelRouteHistoryRow(
      sessionID: key,
      routeEpoch: route.epoch,
      group: group,
      groupID: route.group,
      memberID: route.member,
      provider: route.specifier.provider,
      model: route.specifier.model,
      reason: route.reason.rawValue,
      placedAt: SQLiteDateFormat.string(from: route.placedAt),
      payload: payload,
    )
    try SessionModelRouteHistoryRow.insert { decision }.execute(db)
  }
}
