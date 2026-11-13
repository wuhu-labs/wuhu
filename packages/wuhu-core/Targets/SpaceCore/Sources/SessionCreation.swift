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
    let query = CreationSessionRow.where { $0.id.eq(key) }
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
    let row = CreationSessionRow(
      id: id.rawValue, allocation: allocation, kind: creation.kind.rawValue, parent: creation.parent?.rawValue,
      title: creation.title, tags: try Sessions.encode(creation.tags), createdBy: creation.createdBy,
      executor: executor.kind, executorConfig: executor.configJSON, createdAt: now, lastActivityAt: now,
      hold: "normal", work: "no_work", lifecycle: "live", runState: "no_run", group: creation.group.rawValue, firing: creation.observer?.firing,
    )
    try db.execute(CreationSessionRow.insert { row })
    try db.execute(CreationRuntimeRow.insert { CreationRuntimeRow(sessionID: id.rawValue, generation: 0, queueTail: 0) })
    if let head {
      for (offset, line) in head.lines(session: id).enumerated() {
        let row = SessionLineRow(
          sessionID: id.rawValue, generation: 0, position: Int64(offset + 3), at: SQLiteDateFormat.string(from: line.at),
          role: line.role.rawValue, key: line.key, message: try Sessions.encode(line.message), meta: try line.meta.map(Sessions.encode),
        )
        try db.execute(SessionLineRow.insert { row })
      }
    }
  }

  public static func ancestors(of key: String, in db: Wuwei.Database) -> [String] {
    var chain: [String] = []
    var cursor = db.rows(CreationSessionRow.where { $0.id.eq(key) }.select(\.parent)).first.flatMap(\.self)
    while let parent = cursor {
      precondition(chain.count < 4096, "session tree cycle above \(key)")
      chain.append(parent)
      cursor = db.rows(CreationSessionRow.where { $0.id.eq(parent) }.select(\.parent)).first.flatMap(\.self)
    }
    return chain
  }

  public static func checkParent(_ id: SessionID, in db: Wuwei.Database) throws {
    let key = id.rawValue
    guard let row = db.rows(CreationSessionRow.where { $0.id.eq(key) }).first else { throw SessionStoreError.unknownSession(key) }
    guard row.lifecycle == "live" else { throw SessionStoreError.parentUnavailableForCreation(key) }
    guard ancestors(of: key, in: db).count + 2 <= SessionStore.depthLimit else { throw SessionStoreError.tooDeep(key) }
  }

  public static func markErrored(_ id: SessionID, message: String, at: Date, in db: inout Wuwei.Database) throws -> PersonNote {
    let key = id.rawValue
    let now = SQLiteDateFormat.string(from: at)
    guard let row = db.rows(CreationSessionRow.where { $0.id.eq(key) }).first else { throw SessionStoreError.unknownSession(key) }
    try db.execute(CreationSessionRow.where { $0.id.eq(key) }.update {
      $0.work = "errored"
      $0.errorMessage = #bind(message)
      $0.lastActivityAt = now
      $0.runState = "no_run"
      $0.runProgressAt = #bind(Optional<String>.none)
    })
    let generation = db.rows(CreationRuntimeRow.where { $0.sessionID.eq(key) }.select(\.generation)).first!
    let said = try db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.role.eq(TranscriptLine.Role.assistant.rawValue) }.order { $0.position.desc() }.limit(1)).first.map { try StoredTranscriptLine(row: $0).line().message.text }
    return PersonNote(source: key, group: GroupID(rawValue: row.group), kind: .sessionErrored, payload: try Sessions.encode(Notifications.ErroredPayload(sessionID: key, error: message, message: said)), createdAt: now)
  }
}

@Table("sessions")
private struct CreationSessionRow {
  @Column(primaryKey: true) var id: String
  var allocation: Int64
  var kind: String
  var parent: String?
  var title: String
  var tags: String
  @Column("created_by") var createdBy: String
  var executor: String
  @Column("executor_config") var executorConfig: String
  @Column("created_at") var createdAt: String
  @Column("last_activity_at") var lastActivityAt: String
  var hold: String
  var work: String
  var lifecycle: String
  @Column("run_state") var runState: String
  @Column("grp") var group: String
  var firing: String?
  @Column("grace_expires_at") var graceExpiresAt: String? = nil
  @Column("error_message") var errorMessage: String? = nil
  @Column("run_progress_at") var runProgressAt: String? = nil
}

@Table("session_runtime")
private struct CreationRuntimeRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  var generation: Int64
  @Column("queue_tail") var queueTail: Int64
}

@Selection
private struct CreationSessionRead {
  var session: CreationSessionRow
  var routePayload: String?
}
