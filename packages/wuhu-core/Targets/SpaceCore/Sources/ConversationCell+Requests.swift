#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import SessionDomain
import struct SpaceContract.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

/// A task's report on its request, as it calls the request's conversation with it.
struct Report: Sendable {
  var task: SessionID
  var request: RequestID
  var kind: MessageKind
  var messageID: MessageID
  var text: String
  var at: Date
}

/// A refused final is an answer, not a throw: the refusal it counted stays written.
enum Reported: Sendable {
  case delivered(MessageDelivery)
  case refused(violations: [String], left: Int)
}

extension ConversationCell {
  /// A request of this conversation.
  func request(_ id: RequestID) -> RequestRow? {
    db.rows(RequestRow.where { $0.id.eq(id.rawValue) && $0.conversationID.eq(self.id.key) }).first
  }

  private func open(_ task: SessionID) -> [RequestRow] {
    db.rows(
      RequestRow.where { $0.conversationID.eq(id.key) && $0.task.eq(task.rawValue) && $0.status.eq(RequestStatus.open.rawValue) }.order(by: \.createdAt),
    )
  }

  /// A request is opened on a child by its parent, or on a top-level agent by the person or observer that made it, and a task owes one request at a time. A request that already posted is that one again, never a second.
  func mayOpen(_ id: RequestID, on task: SessionID, from requester: Caller) throws {
    guard let record = session(task.rawValue) else { throw SessionStoreError.unknownSession(task.rawValue) }
    let asks = switch requester {
    case let .session(parent): record.parent == parent.rawValue
    case let .person(person): record.parent == nil && record.createdBy == person.persona && record.group == person.group.rawValue
    case let .observer(observer): record.parent == nil && record.createdBy == observer.member && record.group == observer.group.rawValue
    }
    guard asks else { throw SessionStoreError.notTheParent(task.rawValue) }
    if message(MessageID(id.rawValue)) == nil, let other = open(task).first(where: { $0.id != id.rawValue }) {
      throw SessionStoreError.requestAlreadyOpen(other.id)
    }
  }

  /// Posts the task's report where its requester hears it. A final is checked against the request's schema first: a refused one posts nothing and counts against the request, and the last allowed refusal fails it. A retried report is the first one again.
  mutating func report(_ report: Report) throws -> Reported {
    if let posted = message(report.messageID) {
      return .delivered(MessageDelivery(message: posted, enqueued: [], replayed: true))
    }
    guard let row = request(report.request), row.task == report.task.rawValue, row.requestStatus.isOpen else {
      throw SessionStoreError.unknownRequest(report.request.rawValue)
    }
    var close = RequestStep.progress
    if report.kind == .final {
      if let schema = row.schema {
        let violations = RequestTerms.violations(of: report.text, against: schema)
        guard violations.isEmpty else { return try refuse(report, of: row, violations: violations) }
        close = .close(as: .done, result: JSONValue.parse(report.text)!.jsonString())
      } else {
        close = .close(as: .done, result: JSONValue.string(report.text).jsonString())
      }
    }
    return .delivered(try answer(row, report.kind, id: report.messageID, text: report.text, close, at: report.at))
  }

  /// The task was archived owing reports: each of its open requests fails with a final saying so.
  mutating func archived(_ task: SessionID, title: String, at date: Date) throws {
    for row in open(task) {
      _ = try answer(
        row, .final, id: MessageID(UUID.deterministic("archived-before-reporting", task.rawValue, row.id).uuidString.lowercased()),
        text: "session \(task.rawValue) (\(title)) was archived before reporting on request \(row.id)",
        .close(as: .failed, result: nil), at: date,
      )
    }
  }

  /// A retried attempt, however late, is refused again without counting twice.
  private mutating func refuse(_ report: Report, of row: RequestRow, violations: [String]) throws -> Reported {
    var attempts = JSONValue.parse(row.refusals)!.array!
    if !attempts.contains(.string(report.messageID.rawValue)) {
      attempts.append(.string(report.messageID.rawValue))
      try db.execute(RequestRow.update {
        $0.refusals = #bind(JSONValue.array(attempts).jsonString())
        $0.updatedAt = #bind(SQLiteDateFormat.string(from: report.at))
      }.where { $0.id.eq(row.id) })
    }
    let left = max(RequestTerms.refusalLimit - attempts.count, 0)
    if left == 0 {
      _ = try answer(
        row, .final, id: report.messageID,
        text: "request \(row.id) failed: its final report broke the request's schema \(attempts.count) times; last: \(violations.joined(separator: "; "))",
        .close(as: .failed, result: nil), at: report.at,
      )
    }
    return .refused(violations: violations, left: left)
  }

  /// The task's message to the request's requester: in its DM with a requesting session, else in its own box, where the person asked.
  private mutating func answer(_ row: RequestRow, _ kind: MessageKind, id: MessageID, text: String, _ step: RequestStep, at date: Date) throws -> MessageDelivery {
    try post(Post(
      target: session(row.requester) == nil ? .box : .dm(with: row.requester), messageID: id,
      sender: SessionDomain.Sender(id: row.task, timeZone: TimeZone(identifier: "UTC")!), senderSession: SessionID(row.task),
      kind: kind, requestID: RequestID(row.id), content: MessageContent(text: text), request: step, at: date,
    ))
  }

  /// The request's row changes with the message that says so: a replayed message never comes here.
  mutating func step(_ step: RequestStep, of id: RequestID, at date: Date) throws {
    let now = SQLiteDateFormat.string(from: date)
    switch step {
    case let .open(requester, task, brief, terms, stallSeconds):
      if request(id) == nil {
        try db.execute(RequestRow.insert {
          RequestRow(
            id: id.rawValue, conversationID: self.id.key, group: session(task.rawValue)!.group, requester: requester.name, firing: requester.firing, task: task.rawValue,
            status: RequestStatus.open.rawValue, brief: brief,
            schema: terms.schema?.jsonString(sortedKeys: true), fields: terms.fields?.jsonString(sortedKeys: true),
            result: nil, refusals: "[]", stallSeconds: stallSeconds,
            createdAt: now, updatedAt: now,
          )
        })
      }
      try remindQuiet(request(id)!, from: date)
    case .progress:
      if let row = request(id) { try remindQuiet(row, from: date) }
    case let .close(status, result):
      guard let row = request(id) else { return }
      try db.execute(RequestRow.update {
        $0.status = #bind(status.rawValue)
        $0.result = #bind(result)
        $0.updatedAt = #bind(now)
      }.where { $0.id.eq(row.id) })
      if session(row.requester) != nil {
        ctx.send(.clear(Sessions.quietTopic(row.id)), to: Recipient<SessionMail>(kind: SessionMail.kind, key: row.requester))
      }
    }
  }

  /// Puts the requester's reminder that the task has reported nothing on the request for its stall seconds since `from`; a later put moves it, the request's end takes it back. Only a live requesting session gets one.
  private mutating func remindQuiet(_ row: RequestRow, from: Date) throws {
    guard let seconds = row.stallSeconds, session(row.requester)?.lifecycle == "live" else { return }
    _ = try put(Sessions.quietReminder(row, seconds: seconds, from: from), to: row.requester, at: from)
  }
}
