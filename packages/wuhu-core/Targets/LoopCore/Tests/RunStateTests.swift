import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct RunStateTests {
  private struct RunRow: Equatable {
    var work: String
    var run: String
    var progress: String?
    var activity: String
  }

  private func row(_ space: Space, _ id: SessionID) async throws -> RunRow {
    let rows = try await space.query(
      "SELECT work, run_state, run_progress_at, last_activity_at FROM sessions WHERE id = ?",
      arguments: [.string(id.rawValue)],
      as: .shared(.anonymous),
    )
    func text(_ cell: Cell) -> String? {
      if case let .text(value) = cell { return value }
      return nil
    }
    let cells = try #require(rows.rows.first)
    return RunRow(work: text(cells[0]) ?? "", run: text(cells[1]) ?? "", progress: text(cells[2]), activity: text(cells[3]) ?? "")
  }

  // A session can sit for hours in one exec (say, a find blocked on a macOS
  // consent prompt) and through server restarts. Its row must show the wait
  // for what it is, not read no_run with last_activity_at = its creation time.
  @Test func `a session waiting in a long exec reads tool until a restart and no_run once it settles`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "test_tool", arguments: .object(["command": .string("find ~")]))]),
        Fix.replying("found it"),
      ])
      let release = Latch()
      let exec = ExecScript { _ in
        await release.wait(unless: { Task.isCancelled })
        try Task.checkCancellation()
        return .exec(.init(output: "found", exitCode: 0))
      }
      let config = makeConfig(executeTool: { try await exec($0) }, inference: { try await script($0) })

      var waiting: RunRow?
      let service = SessionExecution(space: space, loopConfig: config)
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let created = try await row(space, sid)
      #expect(created.run == "no_run")
      await time.advance(by: 60)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("find the script"), to: sid)
        try await until("exec engaged") { exec.calls.value.count == 1 }
        let inTool = try await row(space, sid)
        #expect(inTool.work == "has_work")
        #expect(inTool.run == "tool")
        #expect(inTool.progress != nil)
        #expect(inTool.activity == inTool.progress)
        #expect(inTool.activity > created.activity)
        waiting = inTool
      }

      // The server went down mid-exec: nothing about the wait changed.
      #expect(try await row(space, sid) == waiting)
      await time.advance(by: 3600)

      // The drain answers the call that the restart ended, and the model goes on from there.
      try await runService(space, config) { _ in
        try await until("settled") { try await sessions.settledWork(sid) }
      }
      #expect(exec.calls.value.count == 1)
      let answered = try await sessions.lines(sid).first { $0.role == .toolResult && $0.message.toolResult?.isError == true }
      #expect(answered?.text == serverRestartedToolMessage)

      let settled = try await row(space, sid)
      #expect(settled.run == "no_run")
      #expect(settled.progress == nil)
      let began = try #require(waiting)
      #expect(settled.activity > began.activity)
      #expect(script.count == 2)
    }
  }

  @Test func `a session waiting on the model reads inference, held or resumed included`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([Fix.hanging, Fix.hanging])
      let config = makeConfig(inference: { try await script($0) })

      let service = SessionExecution(space: space, loopConfig: config)
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("inference engaged") { script.count == 1 }
        let thinking = try await row(space, sid)
        #expect(thinking.run == "inference")
        #expect(thinking.progress != nil)

        try await service.interrupt(sid)
        try await until("held") { try await row(space, sid).run == "no_run" }
        try await service.resume(sid)
        try await until("the step asked again") { script.count == 2 }
        #expect(try await row(space, sid).run == "inference")
      }
    }
  }
}
