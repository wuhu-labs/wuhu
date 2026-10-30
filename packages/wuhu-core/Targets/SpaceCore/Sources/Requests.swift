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
  case open, stalled, overdue, done, failed

  var isOpen: Bool { self != .done && self != .failed }
}

/// What a requester sets on a request besides its brief. A key makes the
/// create idempotent within the requester's group: a second create with the
/// same kind and key returns the first request.
public struct RequestTerms: Hashable, Sendable {
  static let refusalLimit = 3

  public var kind: String?
  public var key: String?
  public var schema: JSONValue?
  public var fields: JSONValue?

  public init(kind: String? = nil, key: String? = nil, schema: JSONValue? = nil, fields: JSONValue? = nil) throws(RequestTermsError) {
    guard kind != "", key != "" else { throw RequestTermsError(message: "kind and key are nonempty when given") }
    guard key == nil || kind != nil else { throw RequestTermsError(message: "a key needs a kind: the key is unique per kind") }
    if let schema {
      do throws(JSONSchemaError) { _ = try JSONSchema(schema) } catch { throw RequestTermsError(message: "schema: \(error)") }
    }
    if let fields, fields.object == nil { throw RequestTermsError(message: "fields is a JSON object") }
    self.kind = kind; self.key = key; self.schema = schema; self.fields = fields
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
  var kind: String?
  var key: String?
  var status: String
  var brief: String
  var schema: String?
  var fields: String?
  var result: String?
  /// The ids of the refused final attempts, a JSON array.
  var refusals: String
  @Column("deadline_at") var deadlineAt: String?
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

  /// Who holds the request's clocks: the requesting session, else the task,
  /// whose stall clock then moves the row without alerting anyone.
  func clockOwner(in db: Database) throws -> String {
    try requesterSession(in: db)?.rawValue ?? task
  }

  static func find(_ id: RequestID, in db: Database) throws -> Self? {
    try Self.where { $0.id.eq(id.rawValue) }.fetchOne(db)
  }

  static func keyed(_ group: GroupID, _ terms: RequestTerms, in db: Database) throws -> Self? {
    guard let kind = terms.kind, let key = terms.key else { return nil }
    return try Self.where { $0.group.eq(group.rawValue) && $0.kind.eq(kind) && $0.key.eq(key) }.fetchOne(db)
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

/// A keyed create lost to the request that holds its key; nothing it would
/// have written stays.
public struct RequestKeyTaken: Error, Hashable, Sendable {
  public let existing: RequestID
}

extension SessionStore {
  /// Inserts the request's row unless it exists. A key already used in the
  /// group throws `RequestKeyTaken`, so the unique index, not a prior read,
  /// decides which of two racing creates wins.
  static func insertRequest(
    _ id: RequestID, group: GroupID, requester: Caller, task: SessionID, brief: String, terms: RequestTerms, deadline: Date?, now: String, in db: Database,
  ) throws {
    guard try RequestRow.find(id, in: db) == nil else { return }
    try RequestRow.insert {
      RequestRow(
        id: id.rawValue, group: group.rawValue, requester: requester.name, firing: requester.firing, task: task.rawValue,
        kind: terms.kind, key: terms.key, status: RequestStatus.open.rawValue, brief: brief,
        schema: terms.schema?.jsonString(sortedKeys: true), fields: terms.fields?.jsonString(sortedKeys: true),
        result: nil, refusals: "[]", deadlineAt: deadline.map(SQLiteDateFormat.string(from:)), createdAt: now, updatedAt: now,
      )
    } onConflict: { ($0.group, $0.kind, $0.key) }.execute(db)
    guard db.changesCount == 1 else {
      throw RequestKeyTaken(existing: RequestID(try RequestRow.keyed(group, terms, in: db)!.id))
    }
  }

  /// The request a keyed create in `requester`'s group already made.
  public func keyedRequest(by requester: Caller, _ terms: RequestTerms) async throws -> (request: RequestID, task: SessionID)? {
    try await writer.read { db in
      try RequestRow.keyed(Self.group(of: requester, in: db), terms, in: db).map { (RequestID($0.id), SessionID($0.task)) }
    }
  }

  static func group(of caller: Caller, in db: Database) throws -> GroupID {
    switch caller {
    case let .session(id): try Sessions.group(of: id.rawValue, in: db)
    case let .person(person): person.group
    case let .observer(observer): observer.group
    }
  }

  /// Opens a request on a child, or, for a person, on the top-level agent
  /// their page created, in its box. A create whose kind and key the group
  /// already used delivers nothing and answers with that request's message,
  /// as a replay does.
  public func openRequest(
    on task: SessionID,
    from requester: Caller,
    messageID: MessageID,
    text: String,
    deadline: Date?,
    stallSeconds: Double? = nil,
    terms: RequestTerms = .none,
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    let request = RequestID(messageID.rawValue)
    precondition(deadline == nil || requester.session != nil, "a person's request has no deadline")
    if let existing = try await keyedRequest(by: requester, terms)?.request, existing != request {
      return try await existingRequest(existing)
    }
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
    // The row and the clocks commit with the message: a request that exists
    // has its deadline and stall alert, and a replayed one keeps the ones it got.
    do {
      let clocks = requester.session?.rawValue ?? key
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
          try Self.insertRequest(request, group: group, requester: requester, task: task, brief: text, terms: terms, deadline: deadline, now: now, in: db)
          if let deadline {
            try self.armSubscription(
              clocks,
              slot: .init(id: .deadline(request), kind: .requestDeadline(request: request, task: task)),
              nextFireAt: deadline, marker: nil, now: now, in: db,
            )
          }
          if let stallSeconds {
            let opened = message.createdAt
            try self.armSubscription(
              clocks,
              slot: .init(id: .stall(request), kind: .requestStall(.init(request: request, task: task, seconds: stallSeconds, openedAt: opened))),
              nextFireAt: opened.addingTimeInterval(stallSeconds), marker: nil, now: now, in: db,
            )
          }
        },
      )
    } catch let taken as RequestKeyTaken {
      return try await existingRequest(taken.existing)
    }
  }

  private func existingRequest(_ id: RequestID) async throws -> MessageDelivery {
    guard let message = try await message(MessageID(id.rawValue)) else { throw SessionStoreError.unknownRequest(id.rawValue) }
    return MessageDelivery(message: message, enqueued: [], replayed: true)
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
          try RequestRow.setStatus(request, from: [.stalled], to: .open, now: now, in: db)
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

  /// A request's final status, with its clocks ended in the same write.
  static func close(_ row: RequestRow, as status: RequestStatus, result: String?, now: String, in db: Database) throws {
    try RequestRow.update {
      $0.status = #bind(status.rawValue)
      $0.result = #bind(result)
      $0.updatedAt = #bind(now)
    }.where { $0.id.eq(row.id) }.execute(db)
    let owner = try row.clockOwner(in: db)
    try deleteSubscription(owner, .deadline(RequestID(row.id)), in: db)
    try deleteSubscription(owner, .stall(RequestID(row.id)), in: db)
  }

  public func recordRequestDeadline(
    parent: SessionID,
    task: SessionID,
    request: RequestID,
    deadline: Date,
  ) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try recordRequestDeadline(parent: parent, task: task, request: request, deadline: deadline, now: now, in: db)
    }
  }

  func recordRequestDeadline(
    parent: SessionID,
    task: SessionID,
    request: RequestID,
    deadline: Date,
    now: String,
    in db: Database,
  ) throws {
    try RequestRow.setStatus(request, from: [.open, .stalled], to: .overdue, now: now, in: db)
    try Notifications.append(
      recipient: Notifications.ownerRecipient,
      source: parent.rawValue,
      group: try Sessions.group(of: parent.rawValue, in: db),
      kind: .requestDeadline,
      payload: try Sessions.encode(Notifications.RequestDeadlinePayload(
        sessionID: task.rawValue,
        parent: parent.rawValue,
        requestID: request.rawValue,
        deadlineAt: deadline.timeIntervalSince1970,
      )),
      now: now,
      in: db,
    )
  }

  // An errored or killed child with an open request tells its requester so;
  // fabricating a final on its behalf is the one thing that must never happen.
  func notifyParentOfFailure(_ key: String, error: String, now: String, in db: Database) throws -> SessionID? {
    guard let open = try RequestRow.open(task: key, in: db).first else { return nil }
    let requester = try open.requesterSession(in: db)
    let nowDate = try SQLiteDateFormat.date(from: now)
    let notification = SystemNotification(
      id: UUID.deterministic("child-failed", key, open.id),
      timestamp: nowDate,
      kind: .childFailed,
      subscriptionID: .deadline(RequestID(open.id)),
      requestID: RequestID(open.id),
      content: .init(text: "session \(key) failed with an open request \(open.id) and sent no final report: \(error)"),
    )
    let enqueued = try requester.map { (try? Sessions.enqueue($0.rawValue, input: .notification(notification), nowDate: nowDate, in: db)) != nil } ?? false
    try Notifications.append(
      recipient: Notifications.ownerRecipient,
      source: open.requester,
      group: GroupID(rawValue: open.group),
      kind: .childFailed,
      payload: try Sessions.encode(Notifications.ChildFailedPayload(
        sessionID: key, parent: open.requester, requestID: open.id, error: error,
      )),
      now: now,
      in: db,
    )
    return enqueued ? requester : nil
  }
}
