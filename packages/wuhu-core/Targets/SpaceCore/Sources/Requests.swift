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
  @Column("conversation_id") var conversationID: String
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

  static func open(task: String, in db: Database) throws -> [Self] {
    try Self.where { $0.task.eq(task) && $0.status.in(RequestStatus.allCases.filter(\.isOpen).map(\.rawValue)) }
      .order(by: \.createdAt).fetchAll(db)
  }
}

extension SessionStore {
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

  /// Opens a request on a child, or, for a person, on the top-level agent their page created, in its box. The conversation checks who asks and writes the row with the message.
  public func openRequest(
    on task: SessionID,
    from requester: Caller,
    messageID: MessageID,
    text: String,
    stallSeconds: Double? = nil,
    terms: RequestTerms = .none,
  ) async throws -> MessageDelivery {
    let post = Post(
      target: requester.session == nil ? .box : .dm(with: task.rawValue), messageID: messageID,
      sender: Sender(id: requester.name, timeZone: TimeZone(identifier: "UTC")!), senderSession: requester.session,
      kind: .request, requestID: RequestID(messageID.rawValue), content: MessageContent(text: text), acting: requester.principal,
      request: .open(requester: requester, task: task, brief: text, terms: terms, stallSeconds: stallSeconds), at: dateGen.now,
    )
    return try await runtime.worker().call(Self.requests(of: task, askedBy: requester.session)) { try $0.post(post) }
  }

  /// Posts a report from the task to the request's requester. A refused final throws `reportRefused` with what is left.
  public func report(
    _ task: SessionID,
    request: RequestID,
    kind: MessageKind,
    messageID: MessageID,
    text: String,
  ) async throws -> MessageDelivery {
    let report = Report(task: task, request: request, kind: kind, messageID: messageID, text: text, at: dateGen.now)
    switch try await runtime.worker().call(Self.requests(of: task, askedBy: try await record(task).parent), { try $0.report(report) }) {
    case let .delivered(delivery): return delivery
    case let .refused(violations, left): throw SessionStoreError.reportRefused(request.rawValue, violations: violations, left: left)
    }
  }

  /// Where a task's requests live: its DM with the session that asks, its parent, else its own box.
  static func requests(of task: SessionID, askedBy requester: SessionID?) -> ConversationCell.ID {
    ConversationCell.ID(requester.map { Conversations.dmID($0.rawValue, task.rawValue).rawValue } ?? task.rawValue)
  }
}

extension RequestTerms {
  static func violations(of text: String, against schema: String) -> [String] {
    guard let value = JSONValue.parse(text) else { return ["the final report is not JSON; the request's schema wants a JSON value"] }
    return try! JSONSchema(JSONValue.parse(schema)!).violations(of: value)
  }
}

extension Sessions {
  static func quietTopic(_ request: String) -> String { "quiet:\(request)" }

  /// The requester's reminder that the task has reported nothing on the request for `seconds` since `from`: an input on the request's quiet topic, due then.
  static func quietReminder(_ row: RequestRow, seconds: Double, from: Date) -> SessionPut {
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
    return SessionPut(.notification(notification), topic: quietTopic(row.id), due: from.addingTimeInterval(seconds))
  }
}
