#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import JSONSchema
import enum JSONValue.JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries

enum RequestStatus: String, Hashable, Sendable, Codable, CaseIterable {
  case open, done, failed

  var isOpen: Bool { self != .done && self != .failed }
}

/// What a requester sets on a request besides its brief.
public struct RequestTerms: Hashable, Sendable {
  static let refusalLimit = 3

  public var schema: JSONValue?
  public var fields: JSONValue?

  public init(schema: JSONValue? = nil, fields: JSONValue? = nil) throws(RequestTermsError) {
    if let schema {
      do throws(JSONSchemaError) { _ = try JSONSchema(schema) } catch { throw RequestTermsError(message: "schema: \(error)") }
    }
    if let fields, fields.object == nil { throw RequestTermsError(message: "fields is a JSON object") }
    self.schema = schema; self.fields = fields
  }

  public static let none = try! RequestTerms()
}

public struct RequestTermsError: Error, Hashable, Sendable {
  public var message: String
}

@Table("requests")
struct RequestRow {
  @Column(primaryKey: true) var id: String
  @Column("grp") var group: String
  var requester: String
  var firing: String?
  var task: String
  var status: String
  var brief: String
  var schema: String?
  var fields: String?
  var result: String?
  /// The ids of the refused final attempts, a JSON array.
  var refusals: String
  @Column("stall_seconds") var stallSeconds: Double?
  @Column("created_at") var createdAt: String
  @Column("updated_at") var updatedAt: String

  var requestStatus: RequestStatus { RequestStatus(rawValue: status)! }

  /// The session that asked, or nil when a person did through a page.
  func requesterSession(in db: Database) throws -> SessionID? {
    try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sessions WHERE id = ?)", arguments: [requester])! ? SessionID(requester) : nil
  }

  /// Where the task answers: its DM with a requesting session, else its own
  /// box, where the person asked.
  func replyTarget(in db: Database) throws -> ConversationTarget {
    try requesterSession(in: db).map { .dm(with: $0.rawValue) } ?? .box(SessionID(task))
  }

  static func find(_ id: RequestID, in db: Database) throws -> Self? {
    try Self.where { $0.id.eq(id.rawValue) }.fetchOne(db)
  }

  static func open(task: String, in db: Database) throws -> [Self] {
    try Self.where { $0.task.eq(task) && $0.status.in(RequestStatus.allCases.filter(\.isOpen).map(\.rawValue)) }
      .order(by: \.createdAt).fetchAll(db)
  }

  static func setStatus(_ id: RequestID, from: [RequestStatus], to status: RequestStatus, now: String, in db: Database) throws {
    try Self.update {
      $0.status = #bind(status.rawValue)
      $0.updatedAt = #bind(now)
    }.where { $0.id.eq(id.rawValue) && $0.status.in(from.map(\.rawValue)) }.execute(db)
  }
}

extension SessionStore {
  /// Inserts the request's row unless it exists.
  static func insertRequest(
    _ id: RequestID, group: GroupID, requester: Caller, task: SessionID, brief: String, terms: RequestTerms, stallSeconds: Double?,
    now: String, in db: Database,
  ) throws {
    guard try RequestRow.find(id, in: db) == nil else { return }
    try RequestRow.insert {
      RequestRow(
        id: id.rawValue, group: group.rawValue, requester: requester.name, firing: requester.firing, task: task.rawValue,
        status: RequestStatus.open.rawValue, brief: brief,
        schema: terms.schema?.jsonString(sortedKeys: true), fields: terms.fields?.jsonString(sortedKeys: true),
        result: nil, refusals: "[]", stallSeconds: stallSeconds,
        createdAt: now, updatedAt: now,
      )
    }.execute(db)
  }

  /// The requests `requester` opened that still wait on their final, oldest first.
  public func awaitedRequests(_ requester: SessionID) async throws -> [AwaitedRequest] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: """
      SELECT r.id, r.task,
        COALESCE((SELECT MAX(m.created_at) FROM messages AS m WHERE m.request_id = r.id AND m.kind = 'progress'), r.created_at) AS heard
      FROM requests AS r WHERE r.requester = ? AND r.status = 'open' ORDER BY r.created_at, r.id
      """, arguments: [requester.rawValue]).map { row in
        AwaitedRequest(
          id: RequestID(row["id"]), task: SessionID(row["task"]),
          lastHeard: try SQLiteDateFormat.date(from: row["heard"]),
        )
      }
    }
  }

  public func openRequests(_ id: SessionID) async throws -> [OpenRequest] {
    try await writer.read { db in
      _ = try Sessions.record(id.rawValue, in: db)
      return try RequestRow.open(task: id.rawValue, in: db).map {
        OpenRequest(id: RequestID($0.id))
      }
    }
  }

  /// Opens a request on a child, or, for a person, on the top-level agent
  /// their page created, in its box.
  public func openRequest(
    on task: SessionID,
    from requester: Caller,
    messageID: MessageID,
    text: String,
    stallSeconds: Double? = nil,
    terms: RequestTerms = .none,
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    let request = RequestID(messageID.rawValue)
    let group = try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      switch requester {
      case let .session(parent):
        guard record.parent == parent else { throw SessionStoreError.notTheParent(key) }
      case let .person(person):
        guard record.parent == nil, record.createdBy == person.persona, record.group == person.group else {
          throw SessionStoreError.notTheParent(key)
        }
      case let .observer(observer):
        guard record.parent == nil, record.createdBy == observer.member, record.group == observer.group else {
          throw SessionStoreError.notTheParent(key)
        }
      }
      // A retry of a request that already posted replays it: that request is
      // the open one, not a second.
      if try Conversations.message(id: messageID.rawValue, in: db) == nil,
         let open = try RequestRow.open(task: key, in: db).first(where: { $0.id != request.rawValue })
      {
        throw SessionStoreError.requestAlreadyOpen(open.id)
      }
      return record.group
    }
    // The row and its quiet reminder commit with the message; a replayed
    // request keeps the ones it got.
    return try await post(
      requester.session == nil ? .box(task) : .dm(with: key),
      messageID: messageID,
      sender: Sender(id: requester.name, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: requester.session,
      kind: .request,
      requestID: request,
      content: MessageContent(text: text),
      acting: requester.principal,
      alongside: { message, db in
        let now = SQLiteDateFormat.string(from: message.createdAt)
        try Self.insertRequest(
          request, group: group, requester: requester, task: task, brief: text, terms: terms, stallSeconds: stallSeconds,
          now: now, in: db,
        )
        if try Sessions.remindQuiet(RequestRow.find(request, in: db)!, from: message.createdAt, in: db) {
          let runtime = self.runtime
          db.afterNextTransaction { _ in runtime.poke(requester.session!) }
        }
      },
    )
  }

  /// Posts a report from the task to the request's requester. A final checks
  /// the request's schema first: a refused one posts nothing, counts against
  /// the request, and the last allowed refusal fails it.
  public func report(
    _ task: SessionID,
    request: RequestID,
    kind: MessageKind,
    messageID: MessageID,
    text: String,
  ) async throws -> MessageDelivery {
    // A retried report is the first one again: its message stands, and what
    // that message closed stays closed.
    if let posted = try await message(messageID) {
      return MessageDelivery(message: posted, enqueued: [], replayed: true)
    }
    let (row, target) = try await writer.read { db in
      _ = try Sessions.record(task.rawValue, in: db)
      guard let row = try RequestRow.find(request, in: db), row.task == task.rawValue, row.requestStatus.isOpen else {
        throw SessionStoreError.unknownRequest(request.rawValue)
      }
      return (row, try row.replyTarget(in: db))
    }
    var result = JSONValue.string(text).jsonString()
    if kind == .final, let schema = row.schema {
      let violations = Self.violations(of: text, against: schema)
      guard violations.isEmpty else {
        try await refuse(row, to: target, messageID: messageID, violations: violations)
      }
      result = JSONValue.parse(text)!.jsonString()
    }
    let finalResult = result
    return try await post(
      target,
      messageID: messageID,
      sender: Sender(id: task.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: task,
      kind: kind,
      requestID: request,
      content: MessageContent(text: text),
      alongside: { message, db in
        let now = SQLiteDateFormat.string(from: message.createdAt)
        if kind == .final {
          try Self.close(row, as: .done, result: finalResult, now: now, in: db)
        } else {
          try Sessions.remindQuiet(row, from: message.createdAt, in: db)
        }
      },
    )
  }

  static func violations(of text: String, against schema: String) -> [String] {
    guard let value = JSONValue.parse(text) else { return ["the final report is not JSON; the request's schema wants a JSON value"] }
    return try! JSONSchema(JSONValue.parse(schema)!).violations(of: value)
  }

  /// A retried attempt, however late, is refused again without counting twice.
  private func refuse(_ row: RequestRow, to target: ConversationTarget, messageID: MessageID, violations: [String]) async throws -> Never {
    let refusals = try await writer.write { db in
      let current = try RequestRow.find(RequestID(row.id), in: db)!
      var attempts = JSONValue.parse(current.refusals)!.array!
      guard !attempts.contains(.string(messageID.rawValue)) else { return attempts.count }
      attempts.append(.string(messageID.rawValue))
      try RequestRow.update {
        $0.refusals = #bind(JSONValue.array(attempts).jsonString())
        $0.updatedAt = #bind(SQLiteDateFormat.string(from: self.dateGen.now))
      }.where { $0.id.eq(row.id) }.execute(db)
      return attempts.count
    }
    let left = max(RequestTerms.refusalLimit - refusals, 0)
    if left == 0 {
      _ = try await post(
        target,
        messageID: messageID,
        sender: Sender(id: row.task, timeZone: TimeZone(identifier: "UTC")!),
        senderSession: SessionID(row.task),
        kind: .final,
        requestID: RequestID(row.id),
        content: MessageContent(text: "request \(row.id) failed: its final report broke the request's schema \(refusals) times; last: \(violations.joined(separator: "; "))"),
        alongside: { message, db in
          try Self.close(row, as: .failed, result: nil, now: SQLiteDateFormat.string(from: message.createdAt), in: db)
        },
      )
    }
    throw SessionStoreError.reportRefused(row.id, violations: violations, left: left)
  }

  /// A request's final status, with its quiet reminder ended in the same write.
  static func close(_ row: RequestRow, as status: RequestStatus, result: String?, now: String, in db: Database) throws {
    try RequestRow.update {
      $0.status = #bind(status.rawValue)
      $0.result = #bind(result)
      $0.updatedAt = #bind(now)
    }.where { $0.id.eq(row.id) }.execute(db)
    guard let requester = try row.requesterSession(in: db) else { return }
    try Sessions.clear(requester.rawValue, topic: Sessions.quietTopic(row.id), in: db)
  }
}

extension Sessions {
  static func quietTopic(_ request: String) -> String { "quiet:\(request)" }

  /// Puts the requester's reminder that the task has reported nothing on the
  /// request for its stall seconds since `from`; a later put moves it, the
  /// request's end takes it back. Only a live requesting session gets one.
  @discardableResult
  static func remindQuiet(_ row: RequestRow, from: Date, in db: Database) throws -> Bool {
    guard let seconds = row.stallSeconds, let requester = try row.requesterSession(in: db),
          try record(requester.rawValue, in: db).lifecycle == .live
    else { return false }
    let minutes = Int((seconds / 60).rounded())
    let span = minutes >= 1 ? "\(minutes) min" : "\(Int(seconds)) s"
    let notification = SystemNotification(
      id: UUID.deterministic("quiet", row.id, SQLiteDateFormat.string(from: from)),
      timestamp: from.addingTimeInterval(seconds),
      kind: .requestStall,
      subscriptionID: SubscriptionID(quietTopic(row.id)),
      requestID: RequestID(row.id),
      content: .init(text: "Request \(row.id) on task \(row.task) has had no progress report for \(span). Check on it: message it, or archive it if it is lost."),
    )
    try enqueue(
      requester.rawValue, input: .notification(notification), topic: quietTopic(row.id), due: from.addingTimeInterval(seconds), nowDate: from, in: db,
    )
    return true
  }
}
