import struct SessionDomain.ExecutorSpecError
import struct SessionDomain.ModelRouteFailure
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionModelRoute
import StructuredQueries
import Wuwei
import WuweiQueries

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

public enum PortableHandoffConflict: Error, Equatable, Sendable {
  case routeChanged
}

public enum SessionModelRoutes {
  public static func route(_ key: String, in db: Wuwei.Database) throws -> SessionModelRoute? {
    let query = SessionModelRouteRow.where { $0.sessionID.eq(key) }
      .leftJoin(ModelRouteTargetRow.all) { $0.sessionID.eq($1.id) }
      .select { route, target in
        StoredModelRoute.Columns(payload: route.payload, executor: target.executor, executorConfig: target.executorConfig)
      }
    guard let row = db.rows(query).first else { return nil }
    guard let executor = row.executor, let config = row.executorConfig else { throw SessionStoreError.unknownSession(key) }
    return try decode(row.payload, stored: SessionExecutor(kind: executor, configJSON: config))
  }

  static func decode(_ payload: String, stored: SessionExecutor) throws -> SessionModelRoute {
    let route = try Sessions.decode(SessionModelRoute.self, from: payload)
    guard stored == .kernel(route.specifier) else {
      throw SessionStoreError.modelRouteInvalid(group: route.group ?? "<direct>", member: route.member ?? "\(route.specifier.provider)/\(route.specifier.model)")
    }
    return route
  }

  public static func history(_ key: String, in db: Wuwei.Database) throws -> [SessionModelRoute] {
    try db.rows(SessionModelRouteHistoryRow.where { $0.sessionID.eq(key) }.order { $0.decisionID })
      .map { try Sessions.decode(SessionModelRoute.self, from: $0.payload) }
  }

  public static func updateFailureIfCurrent(_ key: String, expectedEpoch: String, failure: ModelRouteFailure?, in db: inout Wuwei.Database) throws {
    guard let row = db.rows(SessionModelRouteRow.where { $0.sessionID.eq(key) }).first, row.routeEpoch == expectedEpoch else { return }
    var route = try Sessions.decode(SessionModelRoute.self, from: row.payload)
    route.failure = failure
    let payload = try Sessions.encode(route)
    let phase = failure?.refusing == true ? "waiting" : "pinned"
    try db.execute(SessionModelRouteRow.where { $0.sessionID.eq(row.sessionID) }.update { $0.payload = payload; $0.phase = phase })
  }

  public static func establish(_ key: String, route: SessionModelRoute, in db: inout Wuwei.Database) throws -> SessionModelRoute {
    if let row = db.rows(SessionModelRouteRow.where { $0.sessionID.eq(key) }).first {
      let held = try Sessions.decode(SessionModelRoute.self, from: row.payload)
      if held.group != nil || route.group != nil || (held.specifier == route.specifier && held.bindingFingerprint == route.bindingFingerprint) {
        return held
      }
    }
    try write(key, route: route, in: &db)
    return route
  }

  public static func write(_ key: String, route: SessionModelRoute?, in db: inout Wuwei.Database) throws {
    try db.execute(SessionModelRouteRow.where { $0.sessionID.eq(key) }.delete())
    guard let route else { return }
    let target = try target(key, in: db)
    guard try SessionExecutor(kind: target.executor, configJSON: target.executorConfig) == .kernel(route.specifier),
          (route.group == nil) == (route.member == nil)
    else {
      throw ExecutorSpecError("route must match the stored concrete target")
    }
    let payload = try Sessions.encode(route)
    let row = SessionModelRouteRow(
      sessionID: key, group: target.group, groupID: route.group, memberID: route.member,
      provider: route.specifier.provider, model: route.specifier.model, routeEpoch: route.epoch,
      phase: route.group == nil ? "bound" : "pinned", payload: payload,
    )
    try db.execute(SessionModelRouteRow.insert { row })
    let decision = SessionModelRouteHistoryRow(
      sessionID: key, routeEpoch: route.epoch, group: target.group, groupID: route.group, memberID: route.member,
      provider: route.specifier.provider, model: route.specifier.model, reason: route.reason.rawValue,
      placedAt: SQLiteDateFormat.string(from: route.placedAt), payload: payload,
    )
    try db.execute(SessionModelRouteHistoryRow.insert { decision })
  }

  private static func target(_ key: String, in db: Wuwei.Database) throws -> ModelRouteTargetRow {
    guard let row = db.rows(ModelRouteTargetRow.where { $0.id.eq(key) }).first else {
      throw SessionStoreError.unknownSession(key)
    }
    return row
  }
}

@Table("sessions")
private struct ModelRouteTargetRow {
  @Column(primaryKey: true) var id: String
  var executor: String
  @Column("executor_config") var executorConfig: String
  @Column("grp") var group: String
}

@Selection
private struct StoredModelRoute {
  var payload: String
  var executor: String?
  var executorConfig: String?
}
