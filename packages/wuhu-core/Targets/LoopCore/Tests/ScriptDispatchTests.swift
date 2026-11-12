#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import GRDB
import JSONValue
@testable import LoopCore
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Testing
import WuhuAI

@Suite struct ScriptDispatchTests {
  @Test func archiveResolvesTheUnansweredScriptBeforeResume() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: .test)
      let effects = Box(0)
      let call = ToolCall(id: "script-call", name: "run_script", arguments: .object(["source": "import {query} from 'wuhu:space'; await query('SELECT 1'); await sleep(100000); result('late')"]))
      let inference = InferenceScript([Fix.replying("run", calls: [call]), Fix.replying("next model step")])
      let service = SessionExecution(connection: scriptConnection(query: { effects.withLock { $0 += 1 } }), credential: { _ in "test" }, space: space) { _ in makeConfig(inference: { try await inference($0) }) }
      service.start()
      try await service.enqueue(item: Fix.message("run"), to: session)
      try await until("the script's side effect") { effects.value == 1 }
      try await service.archive(session, force: true)
      try await until("archive and script teardown") {
        try await space.sessions.record(session).lifecycle != .live
          && space.worker.cell(SessionCell.ID(session.rawValue)).runningScripts().isEmpty
      }
      #expect(space.worker.cell(SessionCell.ID(session.rawValue)).turn()?.turn == .model)
      var answers = try await space.sessions.transcriptLines(session).filter { $0.role == .toolResult }
      #expect(answers.count == 1)
      let first = try #require(answers.first)
      guard case let .toolResult(answer) = try first.line().message else { throw UnexpectedCall("tool answer") }
      #expect(answer.isError)
      #expect(answer.content.contains { if case let .text(text) = $0 { text.text == interruptedToolMessage } else { false } })
      try await service.unarchive(session)
      try await until("unarchived") { try await space.sessions.record(session).lifecycle == .live }
      try await service.resume(session)
      try await until("the next model step") { inference.count == 2 && space.worker.cell(SessionCell.ID(session.rawValue)).turn()?.turn == .idle }
      #expect(effects.value == 1)
      answers = try await space.sessions.transcriptLines(session).filter { $0.role == .toolResult }
      #expect(answers.count == 1)
      #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM script_runs") } == 1)
      await service.shutdown()
      try await space.close()
    }
  }

  @Test func handleMintingSkipsAnEndedJobsHandle() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: .test)
      let choices = Box<[UUID]>([])
      @Dependency(\.uuid) var uuid
      let fallback = uuid
      try await withDependencies {
        $0.uuid = .init { choices.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? fallback() }
      } operation: {
        let starts = Box(0)
        let service = SessionExecution(connection: scriptConnection(starts), credential: { _ in "test" }, space: space) { _ in makeConfig() }
        service.start()
        let cell = SessionCell.ID(session.rawValue)
        try await space.worker.call(cell) { try $0.interrupt() }
        let reused = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
        let fresh = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        choices.withLock { $0 = [reused] }
        let first = try await launchHeldScript(space, session, "first")
        try await until("the first script ends") { space.worker.cell(cell).runningScripts().isEmpty }
        choices.withLock { $0 = [reused, fresh] }
        let second = try await launchHeldScript(space, session, "second")
        #expect(first != second)
        #expect(first.key.hasSuffix("script.000000aa"))
        #expect(second.key.hasSuffix("script.000000bb"))
        try await until("the second script ends") { space.worker.cell(cell).runningScripts().isEmpty }
        #expect(starts.value == 2)
        #expect(choices.value.isEmpty)
        #expect(try await space.sessions.transcriptLines(session).filter { $0.role == .toolResult }.count == 2)
        await service.shutdown()
      }
      try await space.close()
    }
  }

  @Test(arguments: ["[]", "{", "{}", "{\"source\":42}"]) func malformedArgumentsKeepTheirToolWrapper(_ arguments: String) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let session = try await space.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: .test)
      let call = ToolCall(id: "invalid", name: "run_script", arguments: .init(emitted: arguments))
      let inference = InferenceScript([Fix.replying("run", calls: [call]), Fix.replying("done")])
      let starts = Box(0)
      let service = SessionExecution(connection: scriptConnection(starts), credential: { _ in "test" }, space: space) { _ in makeConfig(inference: { try await inference($0) }) }
      service.start()
      try await service.enqueue(item: Fix.message("run"), to: session)
      try await until("the argument failure") { try await space.sessions.transcriptLines(session).contains { $0.role == .toolResult } }
      let line = try #require(try await space.sessions.transcriptLines(session).first { $0.role == .toolResult })
      guard case let .toolResult(answer) = try line.line().message else { throw UnexpectedCall("argument failure") }
      let text = answer.content.compactMap { if case let .text(value) = $0 { value.text } else { nil } }.joined()
      #expect(answer.isError)
      if call.arguments.object == nil {
        #expect(text == "run_script: \(InvalidToolArguments(text: arguments))")
      } else {
        #expect(text.hasPrefix("run_script: arguments do not match the tool schema: "))
      }
      #expect(starts.value == 0)
      #expect(space.worker.cell(SessionCell.ID(session.rawValue)).runningScripts().isEmpty)
      #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM script_runs") } == 0)
      await service.shutdown()
      try await space.close()
    }
  }
}

private func launchHeldScript(_ space: Space, _ session: SessionID, _ name: String) async throws -> ScriptJob.ID {
  let call = ToolCall(id: name, name: "run_script", arguments: .object(["source": "result('done')"]))
  return try await space.worker.call(SessionCell.ID(session.rawValue)) { cell in
    let hydration = try cell.rows.hydrate(session)
    var turn = cell.turn() ?? SessionTurn(generation: hydration.generation, position: 1)
    turn.position += 1
    turn.turn = .tools(calls: [call])
    turn.replied = true
    turn.armed = true
    try cell.db.execute(SessionTurn.delete())
    try cell.db.execute(SessionTurn.insert { turn })
    let slot = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0)
    try cell.startScript(slot.call, call, ScriptPlan(call))
    return cell.scriptAt(slot.call.key)!
  }
}
