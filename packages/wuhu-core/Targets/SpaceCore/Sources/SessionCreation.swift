#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei

public struct SessionCreation: Sendable, Codable {
  public var group: GroupID
  public var title: String
  public var kind: SessionKind
  public var parent: SessionID?
  public var tags: [String]
  public var createdBy: String
  public var executor: SessionExecutor
  public var snapshot: StateSnapshot?
  public var modelRoute: SessionModelRoute?
  public var observer: Observer?

  public init(group: GroupID, title: String, kind: SessionKind, parent: SessionID? = nil, tags: [String] = [], createdBy: String, executor: SessionExecutor, snapshot: StateSnapshot? = nil, modelRoute: SessionModelRoute? = nil, observer: Observer? = nil) {
    self.group = group
    self.title = title
    self.kind = kind
    self.parent = parent
    self.tags = tags
    self.createdBy = createdBy
    self.executor = executor
    self.snapshot = snapshot
    self.modelRoute = modelRoute
    self.observer = observer
  }

  public func validate() throws {
    try executor.requireSupported()
    _ = try Sessions.concreteExecutor(executor, route: modelRoute)
  }

  public static func record(_ id: SessionID, in db: Wuwei.Database) throws -> SessionRecord {
    let key = id.rawValue
    let query = SessionDataRow.where { $0.id.eq(key) }
      .leftJoin(SessionModelRouteRow.all) { $0.id.eq($1.sessionID) }
      .select { session, route in CreationSessionRead.Columns(session: session, routePayload: route.payload) }
    guard let stored = db.rows(query).first else { throw SessionStoreError.unknownSession(key) }
    let row = stored.session
    guard let hold = SessionHold(rawValue: row.hold), hold != .unknown,
          let work = SessionWork(rawValue: row.work), work != .unknown
    else { preconditionFailure("unknown stored session state") }
    let lifecycle: SessionLifecycle = row.lifecycle == "live" ? .live : .archived(graceExpiresAt: try SQLiteDateFormat.date(from: row.graceExpiresAt!))
    var executor = try SessionExecutor(kind: row.executor, configJSON: row.executorConfig)
    if case .kernel = executor, let payload = stored.routePayload {
      let route = try SessionModelRoutes.decode(payload, stored: executor)
      if let group = route.group { executor = .modelGroup(id: group, effort: route.specifier.effort) }
    }
    return SessionRecord(
      id: id, kind: SessionKind(rawValue: row.kind)!, parent: row.parent.map { SessionID($0) }, title: row.title,
      tags: try Sessions.decode([String].self, from: row.tags), createdBy: row.createdBy, executor: executor,
      createdAt: try SQLiteDateFormat.date(from: row.createdAt), lastActivityAt: try SQLiteDateFormat.date(from: row.lastActivityAt),
      hold: hold, work: work, errorMessage: row.errorMessage, lifecycle: lifecycle, group: GroupID(rawValue: row.group),
    )
  }

  public static func write(_ creation: Self, id: SessionID, allocation: Int64, at: Date, head: GenerationHead?, in db: inout Wuwei.Database) throws {
    let executor = try Sessions.concreteExecutor(creation.executor, route: creation.modelRoute)
    let now = SQLiteDateFormat.string(from: at)
    let row = SessionDataRow(
      id: id.rawValue, allocation: allocation, kind: creation.kind.rawValue, parent: creation.parent?.rawValue,
      title: creation.title, tags: try Sessions.encode(creation.tags), createdBy: creation.createdBy,
      executor: executor.kind, executorConfig: executor.configJSON, createdAt: now, lastActivityAt: now,
      hold: "normal", work: "no_work", lifecycle: "live", runState: "no_run", group: creation.group.rawValue, firing: creation.observer?.firing,
    )
    try db.execute(SessionDataRow.insert { row })
    try db.execute(SessionRuntimeRow.insert { SessionRuntimeRow(sessionID: id.rawValue, generation: 0, queueTail: 0) })
    if let head {
      try Sessions.appendLines(id.rawValue, generation: 0, head.lines(session: id), in: &db)
    }
  }

  public static func ancestors(of key: String, in db: Wuwei.Database) -> [String] {
    var chain: [String] = []
    var cursor = db.rows(SessionDataRow.where { $0.id.eq(key) }.select(\.parent)).first.flatMap(\.self)
    while let parent = cursor {
      precondition(chain.count < 4096, "session tree cycle above \(key)")
      chain.append(parent)
      cursor = db.rows(SessionDataRow.where { $0.id.eq(parent) }.select(\.parent)).first.flatMap(\.self)
    }
    return chain
  }

  public static func checkParent(_ id: SessionID, in db: Wuwei.Database) throws {
    let key = id.rawValue
    guard let row = db.rows(SessionDataRow.where { $0.id.eq(key) }).first else { throw SessionStoreError.unknownSession(key) }
    guard row.lifecycle == "live" else { throw SessionStoreError.parentUnavailableForCreation(key) }
    guard ancestors(of: key, in: db).count + 2 <= SessionStore.depthLimit else { throw SessionStoreError.tooDeep(key) }
  }

  public static func markErrored(_ id: SessionID, message: String, at: Date, in db: inout Wuwei.Database) throws {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: at)
    guard db.rows(SessionDataRow.where { $0.id.eq(key) }).first != nil else { throw SessionStoreError.unknownSession(key) }
    try db.execute(SessionDataRow.where { $0.id.eq(key) }.update {
      $0.work = "errored"
      $0.errorMessage = #bind(message)
      $0.lastActivityAt = now
      $0.runState = "no_run"
      $0.runProgressAt = #bind(Optional<String>.none)
    })
  }
}

@Table("sessions")
public struct SessionDataRow {
  @Column(primaryKey: true) public var id: String
  public var allocation: Int64
  public var kind: String
  public var parent: String?
  public var title: String
  public var tags: String
  @Column("created_by") public var createdBy: String
  public var executor: String
  @Column("executor_config") public var executorConfig: String
  @Column("created_at") public var createdAt: String
  @Column("last_activity_at") public var lastActivityAt: String
  public var hold: String
  public var work: String
  public var lifecycle: String
  @Column("run_state") public var runState: String
  @Column("grp") public var group: String
  public var firing: String?
  @Column("grace_expires_at") public var graceExpiresAt: String? = nil
  @Column("error_message") public var errorMessage: String? = nil
  @Column("run_progress_at") public var runProgressAt: String? = nil

  public init(id: String, allocation: Int64, kind: String, parent: String?, title: String, tags: String, createdBy: String, executor: String, executorConfig: String, createdAt: String, lastActivityAt: String, hold: String, work: String, lifecycle: String, runState: String, group: String, firing: String?, graceExpiresAt: String? = nil, errorMessage: String? = nil, runProgressAt: String? = nil) {
    self.id = id
    self.allocation = allocation
    self.kind = kind
    self.parent = parent
    self.title = title
    self.tags = tags
    self.createdBy = createdBy
    self.executor = executor
    self.executorConfig = executorConfig
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt
    self.hold = hold
    self.work = work
    self.lifecycle = lifecycle
    self.runState = runState
    self.group = group
    self.firing = firing
    self.graceExpiresAt = graceExpiresAt
    self.errorMessage = errorMessage
    self.runProgressAt = runProgressAt
  }
}

@Table("session_runtime")
public struct SessionRuntimeRow {
  @Column("session_id", primaryKey: true) public var sessionID: String
  public var generation: Int64
  @Column("queue_tail") public var queueTail: Int64
  @Column("step_try") public var stepTry: Int64 = 0

  public init(sessionID: String, generation: Int64, queueTail: Int64) {
    self.sessionID = sessionID
    self.generation = generation
    self.queueTail = queueTail
  }
}

@Selection
private struct CreationSessionRead {
  var session: SessionDataRow
  var routePayload: String?
}
