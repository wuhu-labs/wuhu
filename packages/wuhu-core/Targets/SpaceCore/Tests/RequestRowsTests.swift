import DeterministicDependencies
import Foundation
import JSONValue
import SessionDomain
@testable import SpaceCore
import Testing
import enum Wuwei.Value

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
    func request(_ id: String, on task: SessionID? = nil, _ terms: RequestTerms = .none) async throws -> MessageDelivery {
      try await store.openRequest(on: task ?? self.task, from: .session(parent), messageID: MessageID(id), text: "do \(id)", terms: terms)
    }

    /// The request's row, as the space's cell reads it.
    func row(_ id: String) -> RequestRow? {
      store.space.request(RequestID(id))
    }

    func status(_ id: String) -> String? { row(id)?.status }

    /// The finals posted into the task's request conversation.
    func finals() -> Int {
      let conversation = Conversations.dmID(parent.rawValue, task.rawValue)
      return rig.space.worker.cell(ConversationCell.ID(conversation.rawValue))
        .messages(where: "m.kind = ?", .text(MessageKind.final.rawValue), limit: nil).count
    }
  }

  private func terms(schema: String? = nil, fields: String? = nil) throws -> RequestTerms {
    try RequestTerms(schema: schema.flatMap(JSONValue.parse), fields: fields.flatMap(JSONValue.parse))
  }

  @Test func `a request is a row with its brief and terms`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1", try terms(fields: #"{"pr":7}"#))
    let row = try #require(fleet.row("r1"))
    #expect(row.group == "shared")
    #expect(row.requester == fleet.parent.rawValue)
    #expect(row.task == fleet.task.rawValue)
    #expect(row.status == "open")
    #expect(row.brief == "do r1")
    #expect(row.fields == #"{"pr":7}"#)
  }

  @Test func `bad terms are refused before anything is written`() throws {
    #expect(throws: RequestTermsError.self) { try terms(fields: "[1]") }
    #expect(throws: RequestTermsError.self) { try terms(schema: #"{"type":"nope"}"#) }
  }

  @Test func `a final closes the row with its text as a JSON string result`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1")
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .progress, messageID: MessageID("p1"), text: "half")
    #expect(fleet.status("r1") == "open")
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "done")
    let row = try #require(fleet.row("r1"))
    #expect(row.status == "done")
    #expect(row.result == #""done""#)
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
      #expect(fleet.status("r1") == "open")
    }
    #expect(fleet.finals() == 0)
    await #expect {
      _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f2"), text: "[]")
    } throws: { error in
      guard case let .reportRefused(_, _, left) = error as? SessionStoreError else { return false }
      return left == 0
    }
    let row = try #require(fleet.row("r1"))
    #expect(row.status == "failed")
    #expect(row.refusals == #"["f0","f1","f2"]"#)
    #expect(fleet.finals() == 1)
    #expect(try fleet.store.openRequests(fleet.task).isEmpty, "a failed request is owed no more")
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
    let row = try #require(fleet.row("r1"))
    #expect(row.status == "open")
    #expect(row.refusals == #"["a","b"]"#)
    #expect(fleet.finals() == 0)
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
    let row = try #require(fleet.row("r1"))
    #expect(row.status == "done")
    #expect(row.result == #"{"verdict":"pass"}"#)
  }

  @Test func `a quiet request reminds its requester, a progress report moves the reminder and the final takes it back`() async throws {
    let fleet = try await Fleet()
    func reminders() async throws -> [String] {
      try await fleet.store.deliverMail()
      return try await fleet.store.drainQueue(fleet.parent).items.compactMap {
        if case let .notification(notice) = $0, notice.kind == .requestStall { notice.requestID?.rawValue } else { nil }
      }
    }
    func report(_ id: String, _ kind: MessageKind) async throws {
      _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: kind, messageID: MessageID(id), text: id)
    }
    _ = try await fleet.store.openRequest(on: fleet.task, from: .session(fleet.parent), messageID: MessageID("r1"), text: "do r1", stallSeconds: 600)
    fleet.rig.advance(300)
    try await report("p1", .progress)
    fleet.rig.advance(300)
    #expect(try await reminders() == [])
    fleet.rig.advance(300)
    #expect(try await reminders() == ["r1"])
    try await report("p2", .progress)
    try await report("f1", .final)
    fleet.rig.advance(600)
    #expect(try await reminders() == [])
  }

  @Test func `a requester awaits its open requests, last heard at the latest progress report`() async throws {
    let fleet = try await Fleet(tasks: 2)
    try await fleet.request("r1")
    fleet.rig.advance(60)
    try await fleet.request("r2", on: fleet.tasks[1])
    fleet.rig.advance(60)
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .progress, messageID: MessageID("p1"), text: "half")
    #expect(fleet.store.awaitedRequests(fleet.parent) == [
      AwaitedRequest(id: RequestID("r1"), task: fleet.task, lastHeard: fixedDate.addingTimeInterval(120)),
      AwaitedRequest(id: RequestID("r2"), task: fleet.tasks[1], lastHeard: fixedDate.addingTimeInterval(60)),
    ])
    _ = try await fleet.store.report(fleet.task, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "done")
    #expect(fleet.store.awaitedRequests(fleet.parent).map(\.id) == [RequestID("r2")])
  }

  @Test func `archive fails the open row`() async throws {
    let fleet = try await Fleet()
    try await fleet.request("r1")
    try await fleet.store.closeRequestsForArchive(fleet.task)
    #expect(fleet.status("r1") == "failed")
  }

  @Test func `an observation of requests sees each transition`() async throws {
    let fleet = try await Fleet(tasks: 3)
    let stream = try fleet.rig.space.observeRows(
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
    try await fleet.request("r1")
    try await next("open")
    try await fleet.request("r2", on: fleet.tasks[1])
    try await next("open", "open")
    try await fleet.request("r3", on: fleet.tasks[2])
    try await next("open", "open", "open")
    try await fleet.store.closeRequestsForArchive(fleet.tasks[2])
    try await next("open", "open", "failed")
    _ = try await fleet.store.report(fleet.task, request: r1, kind: .final, messageID: MessageID("f1"), text: "done")
    try await next("done", "open", "failed")
  }
}
