#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import GRDB
import JSONValue
@testable import LoopCore
import MainHub
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Synchronization
import Testing
import WuhuAI
import Wuwei
import struct Wuwei.Database

@Cell struct ScriptLaunch {
  mutating func launch(_ params: ScriptJob.Params) {
    ctx.create(ScriptJob.ID("\(params.session.rawValue):\(params.handle)"), params: params)
  }
}

private final class ScriptCommits: TransactionObserver, Sendable {
  struct Commit: Equatable {
    let phase: String
    let answered: Bool
    let resulted: Bool
    let posts: Int
    let answers: Int
    let notices: Int
    let ends: Int
  }

  let values = Mutex<[Commit]>([])
  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: GRDB.Database) {}
  func databaseDidCommit(_ db: GRDB.Database) {
    do {
      guard let row = try Row.fetchOne(db, sql: """
      SELECT phase, answered, resulted, posts,
        (SELECT count(*) FROM wuwei_mail WHERE json_extract(CAST(payload AS TEXT), '$.scriptAnswered') IS NOT NULL) AS answers,
        (SELECT count(*) FROM wuwei_mail WHERE json_extract(CAST(payload AS TEXT), '$.scriptPosted') IS NOT NULL) AS notices,
        (SELECT count(*) FROM wuwei_mail WHERE json_extract(CAST(payload AS TEXT), '$.scriptEnded') IS NOT NULL) AS ends
      FROM script_runs LIMIT 1
      """) else { return }
      let value = Commit(phase: row["phase"], answered: row["answered"], resulted: row["resulted"], posts: row["posts"], answers: row["answers"], notices: row["notices"], ends: row["ends"])
      values.withLock { if $0.last != value { $0.append(value) } }
    } catch { Issue.record(error) }
  }
}

func scriptConnection(_ starts: Box<Int> = Box(0), query: @escaping @Sendable () async -> Void = {}) -> MainConnection {
  let connection = MainConnection()
  connection.bind(FetchClient { request in
    switch request.url.path {
    case "/v1/context":
      starts.withLock { $0 += 1 }
      return try Response.json(JSONValue.object(["group": "shared", "revs": ["shared": 0]]))
    case "/v1/groups": return try Response.json(JSONValue.array([]))
    case "/v1/tools/query":
      await query()
      return try Response.json(JSONValue.object(["columns": .array([]), "rows": .array([])]))
    default: throw UnexpectedCall(request.url.path)
    }
  })
  return connection
}

func scriptWorker(_ space: Space, starts: Box<Int> = Box(0), query: @escaping @Sendable () async -> Void = {}) {
  let scripts = Scripts()
  let tools = ToolExecutor(main: scriptConnection(starts, query: query), credential: { _ in "test" })
  space.worker.provide(withEscapedDependencies { dependencies in
    LoopClient(space: space, scripts: scripts, tools: tools, store: space.sessions, config: makeConfig(), sleep: { _ in { throw UnexpectedCall("sleep") } }, dependencies: dependencies, scheduler: space.worker.scheduler, handler: { _ in throw UnexpectedCall("handler") })
  })
  space.worker.register(.job(ScriptJob.self))
  space.worker.register(.cell(ScriptLaunch.self))
}

func scriptParams(session: SessionID, source: String, wait: Double = 300, lifetime: Double = 3600) throws -> ScriptJob.Params {
  let call = ToolCall(id: "call", name: "run_script", arguments: .object(["source": .string(source), "wait_seconds": .number(wait), "max_lifetime_seconds": .number(lifetime)]))
  return try .init(session: session, handle: "script.12345678", slot: .init("\(session.rawValue):0:0"), call: call, plan: ScriptPlan(call), yieldBy: nil)
}

func scriptMail(_ space: Space, _ session: SessionID) async throws -> [SessionCell.Message] {
  try await space.writer.read { db in
    try Data.fetchAll(db, sql: "SELECT payload FROM wuwei_mail WHERE recipient = ? ORDER BY rowid", arguments: [SessionCell.ID(session.rawValue).description]).map { try JSONDecoder().decode(SessionCell.Message.self, from: $0) }
  }
}

@Suite struct ScriptJobTests {
  @Test func `the session creates the script job directly and forgets its last mail`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let call = ToolCall(id: "call", name: "run_script", arguments: .object(["source": "result('first')"]))
      let inference = InferenceScript([Fix.replying("run", calls: [call]), Fix.replying("done")])
      let service = SessionExecution(connection: scriptConnection(), credential: { _ in "test" }, space: space) { _ in makeConfig(inference: { try await inference($0) }) }
      let session = try await space.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: .test)
      service.start()
      try await service.enqueue(item: Fix.message("run"), to: session)
      try await until("one tool result and terminal script membership") {
        try await space.sessions.transcriptLines(session).contains { $0.role == .toolResult }
          && space.worker.cell(SessionCell.ID(session.rawValue)).runningScripts().isEmpty
      }
      #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tool_calls") } == 0)
      #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM script_runs WHERE phase = 'ended' AND answered = 1 AND resulted = 1") } == 1)
      await service.shutdown()
      try await space.close()
    }
  }

  @Test(arguments: [false, true]) func `result and ordered updates commit with their progress`(waitFirst: Bool) async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let (release, gate) = AsyncStream<Void>.makeStream()
      let waiting = Box(false)
      scriptWorker(space, query: {
        waiting.withLock { $0 = true }
        for await _ in release { break }
      })
      space.worker.start()
      let session = SessionID("s")
      let source = "import {query} from 'wuhu:space'; " + (waitFirst ? "await query('SELECT 1'); result('first'); update('second'); update('third')" : "result('first'); await query('SELECT 1'); update('second'); update('third')")
      let params = try scriptParams(session: session, source: source, wait: waitFirst ? 0.1 : 300)
      let job = ScriptJob.ID("s:script.12345678")
      let commits = ScriptCommits()
      await space.writer.add(transactionObserver: commits)
      try await space.worker.call(ScriptLaunch.ID("launch")) { $0.launch(params) }
      try await until("the runtime starts") { space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "running" }
      try await until("the runtime waits") { waiting.value }
      if waitFirst { try await time.wake("the job wait", after: 0.1) }
      try await until("one initial answer") { space.worker.job(job).db.rows(ScriptRow.all).first?.answered == true }
      let first = try await scriptMail(space, session)
      #expect(first.count == 1)
      guard case let .scriptAnswered(_, .result(.script(result), _)) = first[0] else { throw UnexpectedCall("script answer") }
      #expect(waitFirst ? result.output.contains("\"running\"") : result.output.hasPrefix("first"))
      gate.yield(())
      try await until("the runtime ends") { space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "ended" }
      let mail = try await scriptMail(space, session)
      let posted = mail.compactMap { if case let .scriptPosted(_, text) = $0 { text } else { nil } }
      let expected = waitFirst ? ["result of script.12345678:\nfirst", "second", "third"] : ["second", "third"]
      #expect(posted == expected)
      guard case .scriptEnded = mail.last else { throw UnexpectedCall("script terminal mail") }
      for commit in commits.values.withLock({ $0 }) {
        if commit.answered { #expect(commit.answers == 1) }
        #expect(commit.notices == commit.posts + (waitFirst && commit.resulted ? 1 : 0))
        if commit.phase == "ended" { #expect(commit.ends == 1) }
      }
      try await space.close()
    }
  }

  @Test(arguments: [false, true]) func `drain ends once before or after the answer and never reruns JavaScript`(answered: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("script-drain")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let starts = Box(0)
      scriptWorker(old, starts: starts)
      scriptWorker(new, starts: starts)
      old.worker.start()
      let params = try scriptParams(session: .init("s"), source: (answered ? "result('started'); " : "") + "await sleep(100000)")
      let job = ScriptJob.ID("s:script.12345678")
      try await old.worker.call(ScriptLaunch.ID("launch")) { $0.launch(params) }
      try await until("the runtime starts") { starts.value == 1 }
      if answered { try await until("the script answers") { old.worker.job(job).db.rows(ScriptRow.all).first?.answered == true } }
      new.worker.start()
      await old.stopWorker()
      await time.advance(by: 2)
      try await until("the replacement sees the tombstone") { new.worker.job(job).db.rows(ScriptRow.all).first?.phase == "ended" }
      let mail = try await scriptMail(new, .init("s"))
      #expect(mail.filter { if case .scriptAnswered = $0 { true } else { false } }.count == 1)
      #expect(mail.filter { if case .scriptPosted = $0 { true } else { false } }.count == (answered ? 1 : 0))
      #expect(mail.filter { if case .scriptEnded = $0 { true } else { false } }.count == 1)
      #expect(starts.value == 1)
      try await old.close()
      try await new.close()
    }
  }
}
