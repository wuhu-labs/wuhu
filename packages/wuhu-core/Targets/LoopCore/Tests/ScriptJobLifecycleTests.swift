#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
@testable import LoopCore
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Testing
import Wuwei
import struct Wuwei.Database

@Job private struct CrashedScript {
  static let kind = ScriptJob.kind
  static let schema = ScriptJob.schema
  typealias Message = ScriptJob.Message
  typealias Params = ScriptJob.Params

  static func create(ctx: inout JobContext<Self>) throws {
    let params = ctx.params
    let answered = params.plan.source == "answered"
    if answered { ctx.send(SessionCell.ID(params.session.rawValue)).scriptAnswered(params.slot, .result(.script(.init(output: "original")), context: nil)) }
    let row = ScriptRow(phase: "running", waitUntil: Date(ctx.now), lifetimeUntil: Date(ctx.now).addingTimeInterval(3600), answered: answered)
    try ctx.db.execute(ScriptRow.insert { row })
  }

  mutating func start() async throws -> Outcome {
    do { try await ctx.sleep(for: .seconds(1000)) } catch is CancellationError {}
    return .notDone
  }
}

@Cell private struct CrashLaunch {
  mutating func launch(_ params: ScriptJob.Params) {
    ctx.create(CrashedScript.ID("s:script.12345678"), params: params)
  }
}

@Suite struct ScriptJobLifecycleTests {
  @Test(arguments: [false, true]) func `a crashed started run gets one restart ending without evaluation`(answered: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("script-crash")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let starts = Box(0)
      old.worker.register(.job(CrashedScript.self))
      old.worker.register(.cell(CrashLaunch.self))
      old.worker.start()
      scriptWorker(new, starts: starts)
      let params = try scriptParams(session: .init("s"), source: answered ? "answered" : "unanswered")
      let job = ScriptJob.ID("s:script.12345678")
      try await old.worker.call(CrashLaunch.ID("launch")) { $0.launch(params) }
      try await until("the crashed script has committed its running row") { old.worker.job(job).db.rows(ScriptRow.all).first?.phase == "running" }
      new.worker.start()
      await old.stopWorker()
      await time.advance(by: 2)
      try await until("the replacement ends the committed running row") { new.worker.job(job).db.rows(ScriptRow.all).first?.phase == "ended" }
      let mail = try await scriptMail(new, .init("s"))
      #expect(mail.filter { if case .scriptAnswered = $0 { true } else { false } }.count == 1)
      #expect(mail.filter { if case .scriptPosted = $0 { true } else { false } }.count == (answered ? 1 : 0))
      #expect(mail.filter { if case .scriptEnded = $0 { true } else { false } }.count == 1)
      if !answered {
        guard case .scriptAnswered(_, .serverRestarted) = mail[0] else { throw UnexpectedCall("restart must be the tool failure alone") }
      }
      #expect(starts.value == 0)
      try await old.close()
      try await new.close()
    }
  }

  @Test(arguments: [false, true]) func `cancel and lifetime allow five seconds before killing an uncooperative runtime`(lifetime: Bool) async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      scriptWorker(space)
      space.worker.start()
      let params = try scriptParams(session: .init("s"), source: "result('started'); while (true) {}", lifetime: lifetime ? 1 : 3600)
      let job = ScriptJob.ID("s:script.12345678")
      try await space.worker.call(ScriptLaunch.ID("launch")) { $0.launch(params) }
      try await until("the busy runtime answers") { space.worker.job(job).db.rows(ScriptRow.all).first?.answered == true }
      if lifetime { await time.advance(by: 1) }
      else { space.worker.send(.cancel, to: job) }
      try await until("abort and its deadline commit") { space.worker.job(job).db.rows(ScriptRow.all).first?.killAt != nil }
      await time.advance(by: 4)
      #expect(space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "running")
      await time.advance(by: 1)
      try await until("the grace kills the runtime") { space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "ended" }
      let mail = try await scriptMail(space, .init("s"))
      let notices = mail.compactMap { if case let .scriptPosted(_, text) = $0 { text } else { nil } }
      #expect(notices.count == (lifetime ? 1 : 0))
      if lifetime { #expect(notices[0].contains("max lifetime of 1 s")) }
      try await space.close()
    }
  }

  @Test func `input driven yield returns running while the runtime continues`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      scriptWorker(space)
      space.worker.start()
      let params = try scriptParams(session: .init("s"), source: "await sleep(100000)")
      let job = ScriptJob.ID("s:script.12345678")
      try await space.worker.call(ScriptLaunch.ID("launch")) { $0.launch(params) }
      try await until("the runtime starts") { space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "running" }
      space.worker.send(.yield(by: anchor.addingTimeInterval(10)), to: job)
      try await until("the yield deadline commits") { space.worker.job(job).db.rows(ScriptRow.all).first?.yieldBy != nil }
      await time.advance(by: 10)
      try await until("the yield answers") { space.worker.job(job).db.rows(ScriptRow.all).first?.answered == true }
      guard case let .scriptAnswered(_, .result(.script(answer), _)) = try await scriptMail(space, .init("s"))[0] else { throw UnexpectedCall("yield answer") }
      #expect(answer.output.contains("a message arrived"))
      #expect(space.worker.job(job).db.rows(ScriptRow.all).first?.phase == "running")
      try await space.close()
    }
  }
}
