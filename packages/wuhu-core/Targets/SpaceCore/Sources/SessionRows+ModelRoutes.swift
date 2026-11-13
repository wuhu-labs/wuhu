import GRDB
import SessionDomain
import StructuredQueries

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

extension Sessions {
  static func commitRouteTransition(_ key: String, transition: ModelRouteTransition, in db: Database) throws {
    guard let row = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db), row.routeEpoch == transition.expectedEpoch else { throw PortableHandoffConflict.routeChanged }
    let old = try decode(SessionModelRoute.self, from: row.payload)
    let route = transition.route
    guard route.failure == nil, (route.group == nil) == (route.member == nil) else { throw PortableHandoffConflict.routeChanged }
    let config = SessionExecutor.kernel(route.specifier).configJSON
    if route.epoch == old.epoch {
      var unchanged = route
      unchanged.specifier.effort = old.specifier.effort
      unchanged.failure = old.failure
      guard unchanged == old, route.specifier.effort != old.specifier.effort else { throw PortableHandoffConflict.routeChanged }
      try RouteExecutorRow.where { $0.id.eq(key) }.update { $0.executorConfig = config }.execute(db)
      let payload = try encode(route)
      try SessionModelRouteRow.where { $0.sessionID.eq(key) }.update { $0.payload = payload; $0.phase = route.group == nil ? "bound" : "pinned" }.execute(db)
      return
    }
    guard route.group != old.group || route.member != old.member || route.specifier != old.specifier,
          transition.binding?.epoch == route.epoch else { throw PortableHandoffConflict.routeChanged }
    try RouteExecutorRow.where { $0.id.eq(key) }.update { $0.executorConfig = config }.execute(db)
    try writeModelRoute(key, route: route, in: db)
  }
}

@Table("sessions")
private struct RouteExecutorRow {
  @Column(primaryKey: true) var id: String
  @Column("executor_config") var executorConfig: String
}
