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
  @Test func `a session waiting in a long exec reads tool across a restart and no_run once it settles`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let created = try await row(space, sid)
      #expect(created.run == "no_run")
      await time.advance(by: 60)

      let script = InferenceScript([
        Fix.replying("looking", calls: [.init(id: "call_0", name: "exec", arguments: .object(["command": .string("find ~")]))]),
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
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("find the script"), to: sid)
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

      try await runService(space, config) { _ in
        // Boot rejoins the same call, and the row still dates the wait
        // from when it began.
        try await until("exec rejoined") { exec.calls.value.count == 2 }
        #expect(try await row(space, sid) == waiting)

        release.release()
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let settled = try await row(space, sid)
      #expect(settled.run == "no_run")
      #expect(settled.progress == nil)
      let began = try #require(waiting)
      #expect(settled.activity > began.activity)
      #expect(script.count == 2)
    }
  }

  // A compact command with no instructions runs a real inference from a
  // settled transcript, which on its own derives no_run.
  @Test func `a forced compaction from a settled turn reads inference until it ends`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let release = Latch()
      let compacting = Box(0)
      let config = makeConfig(inference: { request in
        guard request.mode == .forcedCompact else { return Fix.reply("hi") }
        compacting.withLock { $0 += 1 }
        await release.wait(unless: { Task.isCancelled })
        try Task.checkCancellation()
        return Fix.reply("done")
      }, compact: { _ in .init(summary: "folded") })

      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("settled") { try await sessions.settledWork(sid) }
        #expect(try await row(space, sid).run == "no_run")

        try await sessions.requestCommand(sid, .compact(instructions: nil))
        try await until("compaction engaged") { compacting.value == 1 }
        let folding = try await row(space, sid)
        #expect(folding.run == "inference")
        #expect(folding.progress != nil)

        release.release()
        try await until("compaction done") {
          guard try await sessions.pendingCommand(sid) == nil else { return false }
          return try await row(space, sid).run == "no_run"
        }
      }
    }
  }

  @Test func `a session waiting on the model reads inference`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.hanging])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("inference engaged") { script.count == 1 }
        let thinking = try await row(space, sid)
        #expect(thinking.run == "inference")
        #expect(thinking.progress != nil)
      }
    }
  }
}
