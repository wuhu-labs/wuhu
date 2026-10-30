import Dependencies
import GRDB
import SessionDomain
import StructuredQueries
import StructuredQueriesSQLite

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

  public func modelProviderRefusing(provider: String, model: String) async throws -> Bool {
    @Dependency(\.date.now) var now
    return try await writer.read { db in
      for row in try SessionModelRouteRow.where({ $0.provider.eq(provider) && $0.phase.eq("waiting") }).fetchAll(db) {
        let route = try Sessions.decode(SessionModelRoute.self, from: row.payload)
        guard let failure = route.failure, failure.refusing, failure.stands(at: now),
              failure.reason != .upstreamOutage || route.specifier.model == model else { continue }
        let record = try Sessions.record(row.sessionID, in: db)
        guard record.lifecycle == .live, record.hold == .normal else { continue }
        let since = SQLiteDateFormat.string(from: failure.lastFailureAt ?? failure.firstFailureAt)
        let recovered = try InferenceRow.where {
          $0.provider.eq(provider) && $0.grp.eq(row.group) && $0.outcome.eq("ok") && $0.at.gt(since)
        }.fetchAll(db).contains { failure.reason != .upstreamOutage || $0.model == model }
        if !recovered { return true }
      }
      return false
    }
  }

  public func updateModelRouteFailure(_ id: SessionID, expectedEpoch: String, failure: ModelRouteFailure?) async throws {
    let key = id.rawValue
    try await writer.write { db in
      guard let row = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db), row.routeEpoch == expectedEpoch else { throw PortableHandoffConflict.routeChanged }
      var route = try Sessions.decode(SessionModelRoute.self, from: row.payload)
      route.failure = failure
      let payload = try Sessions.encode(route)
      let phase = failure?.refusing == true ? "waiting" : "pinned"
      try SessionModelRouteRow.where { $0.sessionID.eq(key) }.update { $0.payload = payload; $0.phase = phase }.execute(db)
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

extension Sessions {
  static func commitRouteTransition(_ key: String, transition: ModelRouteTransition, in db: Database) throws {
    guard let row = try SessionModelRouteRow.where({ $0.sessionID.eq(key) }).fetchOne(db), row.routeEpoch == transition.expectedEpoch else { throw PortableHandoffConflict.routeChanged }
    let old = try decode(SessionModelRoute.self, from: row.payload)
    let route = transition.route
    guard route.failure == nil, (route.group == nil) == (route.member == nil), transition.transcript.pendingToolCallIDs.isEmpty else { throw PortableHandoffConflict.routeChanged }
    let config = SessionExecutor.kernel(route.specifier).configJSON
    if route.epoch == old.epoch {
      // Effort only: same group intent, member, model and binding, so the
      // transcript replays as it is and history keeps the one decision.
      var unchanged = route
      unchanged.specifier.effort = old.specifier.effort
      unchanged.failure = old.failure
      guard unchanged == old, route.specifier.effort != old.specifier.effort else { throw PortableHandoffConflict.routeChanged }
      try RouteExecutorRow.where { $0.id.eq(key) }.update { $0.executorConfig = config }.execute(db)
      let payload = try encode(route)
      try SessionModelRouteRow.where { $0.sessionID.eq(key) }.update { $0.payload = payload; $0.phase = route.group == nil ? "bound" : "pinned" }.execute(db)
      return
    }
    // A server placement moves within the held group; a requested switch may
    // leave it, join another, or bind to a concrete model.
    guard route.group != old.group || route.member != old.member || route.specifier != old.specifier,
          transition.transcript.replayBinding?.epoch == route.epoch else { throw PortableHandoffConflict.routeChanged }
    guard !transition.transcript.items.contains(where: { item in
      guard case let .assistant(entry) = item else { return false }
      return entry.content.contains { block in
        switch block { case .reasoning(.encrypted), .hostedTool: true; default: false }
      }
    }) else { throw PortableHandoffConflict.routeChanged }
    try RouteExecutorRow.where { $0.id.eq(key) }.update { $0.executorConfig = config }.execute(db)
    try writeModelRoute(key, route: route, in: db)
  }
}

@Table("sessions")
private struct RouteExecutorRow {
  @Column(primaryKey: true) var id: String
  @Column("executor_config") var executorConfig: String
}
