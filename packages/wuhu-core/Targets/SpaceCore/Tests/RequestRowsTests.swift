import DeterministicDependencies
import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SpaceCore
import Testing

// One row per request in `requests`, moved by the write that posts or fires.
@Suite(.deterministicDependencies) struct RequestRowsTests {
  private struct Fleet {
    let rig: MovingClockSpace
    let parent: SessionID
    let tasks: [SessionID]

    var store: SessionStore { rig.store }

    init(tasks count: Int = 1) async throws {
      rig = try MovingClockSpace()
      parent = try await rig.store.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "morgan", model: .test)
      var tasks: [SessionID] = []
      for n in 0 ..< count {
        tasks.append(try await rig.store.createSession(
          group: .shared, title: "task \(n)", kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
        ))
      }
      self.tasks = tasks
    }

    var task: SessionID { tasks[0] }

    @discardableResult
    func request(_ id: String, on task: SessionID? = nil, deadline: Date? = nil, _ terms: RequestTerms = .none) async throws -> MessageDelivery {
      try await store.openRequest(on: task ?? self.task, from: .session(parent), messageID: MessageID(id), text: "do \(id)", deadline: deadline, terms: terms)
    }

    // The row's non-null columns, as text.
    func row(_ id: String) async throws -> [String: String]? {
      try await store.writer.read { db in
        try Row.fetchOne(db, sql: "SELECT * FROM requests WHERE id = ?", arguments: [id]).map { row in
          row.reduce(into: [:]) { columns, column in
            switch column.1.storage {
            case .null: break
            case let .int64(value): columns[column.0] = "\(value)"
            case let .string(value): columns[column.0] = value
            case let .double(value): columns[column.0] = "\(value)"
            case .blob: Issue.record("blob in requests.\(column.0)")
            }
          }
        }
      }
    }

    func status(_ id: String) async throws -> String? { try await row(id)?["status"] }

    func count(_ sql: String) async throws -> Int {
      try await store.writer.read { try Int.fetchOne($0, sql: sql)! }
    }
  }

  private func terms(kind: String? = nil, key: String? = nil, schema: String? = nil, fields: String? = nil) throws -> RequestTerms {
    try RequestTerms(kind: kind, key: key, schema: schema.flatMap(JSONValue.parse), fields: fields.flatMap(JSONValue.parse))
  }

  @Test func `a request is a row with its brief and terms`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1", try terms(kind: "review", key: "pr-7", fields: #"{"pr":7}"#))
    let row = try #require(try await fleet.row("r1"))
    #expect(row["grp"] == "shared")
    #expect(row["requester"] == fleet.parent.rawValue)
    #expect(row["task"] == fleet.task.rawValue)
    #expect(row["kind"] == "review")
    #expect(row["key"] == "pr-7")
    #expect(row["status"] == "open")
    #expect(row["brief"] == "do r1")
    #expect(row["fields"] == #"{"pr":7}"#)
  }

  @Test func `bad terms are refused before anything is written`() throws {
    #expect(throws: RequestTermsError.self) { try terms(key: "k") }
    #expect(throws: RequestTermsError.self) { try terms(kind: "") }
    #expect(throws: RequestTermsError.self) { try terms(fields: "[1]") }
    #expect(throws: RequestTermsError.self) { try terms(schema: #"{"type":"nope"}"#) }
  }

  @Test func `a taken key opens nothing and answers the request that holds it`() async throws {
    let fleet = try await Fleet(tasks: 2)
    let keyed = try terms(kind: "review", key: "pr-7")
    let first = try await fleet.request("r1", keyed)
    _ = try await fleet.store.drainQueue(fleet.task)
    let again = try await fleet.request("r2", on: fleet.tasks[1], keyed)
    #expect(again.message.id == first.message.id)
    #expect(again.enqueued.isEmpty)
    #expect(try await fleet.row("r2") == nil)
    #expect(try await fleet.count("SELECT count(*) FROM messages WHERE kind = 'request'") == 1)
    #expect(try await fleet.store.keyedRequest(by: .session(fleet.parent), keyed)?.task == fleet.task)
    // Another kind is another key space.
    try await fleet.request("r3", on: fleet.tasks[1], try terms(kind: "build", key: "pr-7"))
    #expect(try await fleet.status("r3") == "open")
  }

  @Test func `racing creates with one key make one request`() async throws {
    let fleet = try await Fleet(tasks: 8)
    let keyed = try terms(kind: "review", key: "pr-7")
    let deliveries = try await withThrowingTaskGroup(of: MessageDelivery.self) { group in
      for (n, task) in fleet.tasks.enumerated() {
        group.addTask { try await fleet.request("r\(n)", on: task, keyed) }
      }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(deliveries.map(\.message.id)).count == 1)
    #expect(try await fleet.count("SELECT count(*) FROM requests") == 1)
    #expect(try await fleet.count("SELECT count(*) FROM messages WHERE kind = 'request'") == 1)
  }

  @Test func `a keyed create whose key is taken creates no session`() async throws {
    let fleet = try await Fleet()
    let keyed = try terms(kind: "review", key: "pr-7")
    try await fleet.request("r1", keyed)
    let sessions = try await fleet.count("SELECT count(*) FROM sessions")
    await #expect(throws: RequestKeyTaken(existing: RequestID("r1"))) {
      try await fleet.store.createSession(
        group: .shared, title: "twin", kind: .task, parent: fleet.parent, createdBy: fleet.parent.rawValue,
        executor: .kernel(.test), request: (RequestID("r2"), .session(fleet.parent), "do r2", keyed),
      )
    }
    #expect(try await fleet.count("SELECT count(*) FROM sessions") == sessions)
    #expect(try await fleet.row("r2") == nil)
  }

  @Test func `a final closes the row with its text as a JSON string result`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1")
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .progress, messageID: MessageID("p1"), text: "half")
    #expect(try await fleet.status("r1") == "open")
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "done")
    let row = try #require(try await fleet.row("r1"))
    #expect(row["status"] == "done")
    #expect(row["result"] == #""done""#)
    await #expect(throws: SessionStoreError.unknownRequest("r1")) {
      _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f2"), text: "again")
    }
  }

  @Test func `a schema refuses a mismatched final and fails the request on the last refusal`() async throws {
    let fleet = try await Fleet()
    let schema = #"{"type":"object","required":["verdict"],"properties":{"verdict":{"enum":["pass","fail"]}}}"#
    try await fleet.request("r1", try terms(schema: schema))
    for (n, text) in ["not json", #"{"verdict":"maybe"}"#].enumerated() {
      await #expect {
        _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f\(n)"), text: text)
      } throws: { error in
        guard case let .reportRefused(id, violations, left) = error as? SessionStoreError else { return false }
        return id == "r1" && !violations.isEmpty && left == RequestTerms.refusalLimit - n - 1
      }
      #expect(try await fleet.status("r1") == "open")
    }
    #expect(try await fleet.count("SELECT count(*) FROM messages WHERE kind = 'final'") == 0)
    await #expect {
      _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f2"), text: "[]")
    } throws: { error in
      guard case let .reportRefused(_, _, left) = error as? SessionStoreError else { return false }
      return left == 0
    }
    let row = try #require(try await fleet.row("r1"))
    #expect(row["status"] == "failed")
    #expect(row["refusals"] == #"["f0","f1","f2"]"#)
    #expect(try await fleet.count("SELECT count(*) FROM messages WHERE kind = 'final'") == 1)
  }

  @Test func `a retried refused attempt counts once, however late`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1", try terms(schema: #"{"type":"object"}"#))
    for (attempt, left) in [("a", 2), ("a", 2), ("b", 1), ("a", 1), ("b", 1)] {
      await #expect {
        _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID(attempt), text: "[]")
      } throws: { error in
        guard case let .reportRefused(_, _, refusalsLeft) = error as? SessionStoreError else { return false }
        return refusalsLeft == left
      }
    }
    let row = try #require(try await fleet.row("r1"))
    #expect(row["status"] == "open")
    #expect(row["refusals"] == #"["a","b"]"#)
    #expect(try await fleet.count("SELECT count(*) FROM messages WHERE kind = 'final'") == 0)
  }

  @Test func `a query reads schema, fields and result as JSON columns`() async throws {
    let fleet = try await Fleet(tasks: 2)
    try await fleet.request("r1", try terms(schema: #"{"type":"object"}"#, fields: #"{"pr":7}"#))
    try await fleet.request("r2", on: fleet.tasks[1])
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: #"{"ok":true}"#)
    _ = try await fleet.store.report(fleet.tasks[1], request: RequestID("r2"), kind: .final, messageID: MessageID("f2"), text: "plain text")
    let rows = try await fleet.rig.space.query("SELECT schema, fields, result FROM requests ORDER BY id", as: .shared(.anonymous))
    #expect(rows.decltypes == ["JSON_TEXT", "JSON_TEXT", "JSON_TEXT"])
    #expect(rows.rows == [
      [.text(#"{"type":"object"}"#), .text(#"{"pr":7}"#), .text(#"{"ok":true}"#)],
      [.null, .null, .text(#""plain text""#)],
    ])
  }

  @Test func `a schema'd final stores its JSON as the result`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1", try terms(schema: #"{"type":"object","required":["verdict"]}"#))
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: #" { "verdict" : "pass" } "#)
    let row = try #require(try await fleet.row("r1"))
    #expect(row["status"] == "done")
    #expect(row["result"] == #"{"verdict":"pass"}"#)
  }

  @Test func `a passed deadline marks the row overdue and a final still closes it`() async throws {
    let fleet = try await Fleet()
    let deadline = fixedDate.addingTimeInterval(60)
    try await fleet.request("r1", deadline: deadline)
    #expect(try await fleet.row("r1")?["deadline_at"] == SQLiteDateFormat.string(from: deadline))
    fleet.rig.advance(61)
    try await fleet.store.recordRequestDeadline(parent: fleet.parent, task: fleet.task, request: RequestID("r1"), deadline: deadline)
    #expect(try await fleet.status("r1") == "overdue")
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "late")
    #expect(try await fleet.status("r1") == "done")
  }

  @Test func `archive fails the open row`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1")
    try await fleet.store.closeRequestsForArchive(fleet.task)
    #expect(try await fleet.status("r1") == "failed")
  }

  @Test func `an observation of requests sees each transition`() async throws {
    let fleet = try await Fleet(tasks: 3)
    let stream = await fleet.rig.space.observeQuery(
      "SELECT id, status FROM requests ORDER BY id", throttle: .zero, as: .shared(.anonymous),
    )
    let frames = Collector<[[Cell]]>()
    let watching = Task {
      for try await rows in stream { await frames.append(rows.rows) }
    }
    defer { watching.cancel() }
    var seen = try await awaitItems(frames, atLeast: 1).count
    func next(_ statuses: String...) async throws {
      seen += 1
      let frame = try await awaitItems(frames, atLeast: seen)[seen - 1]
      #expect(frame == statuses.enumerated().map { [.text("r\($0 + 1)"), .text($1)] })
    }
    let r1 = RequestID("r1")
    _ = try await fleet.store.openRequest(on: fleet.task, from: .session(fleet.parent), messageID: MessageID("r1"), text: "do r1", deadline: nil, stallSeconds: 600)
    try await next("open")
    let deadline = fixedDate.addingTimeInterval(60)
    try await fleet.request("r2", on: fleet.tasks[1], deadline: deadline)
    try await next("open", "open")
    try await fleet.request("r3", on: fleet.tasks[2])
    try await next("open", "open", "open")
    fleet.rig.advance(600)
    try await fleet.store.checkRequestStall(fleet.parent, subscriptionID: .stall(r1), now: fixedDate.addingTimeInterval(600))
    try await next("stalled", "open", "open")
    _ = try await fleet.store.report(fleet.task, request: r1, kind: .progress, messageID: MessageID("p1"), text: "half")
    try await next("open", "open", "open")
    try await fleet.store.recordRequestDeadline(parent: fleet.parent, task: fleet.tasks[1], request: RequestID("r2"), deadline: deadline)
    try await next("open", "overdue", "open")
    try await fleet.store.closeRequestsForArchive(fleet.tasks[2])
    try await next("open", "overdue", "failed")
    _ = try await fleet.store.report(fleet.task, request: r1, kind: .final, messageID: MessageID("f1"), text: "done")
    try await next("done", "overdue", "failed")
  }
}
