#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

func seedLegacyGeneration(_ space: Space, _ session: SessionID) async throws {
  let path = await space.writer.path
  let plant = try DatabaseQueue(path: path, configuration: Space.makeConfiguration(journalMode: .default))
  try await plant.write { db in
    try db.execute(sql: "INSERT INTO session_contents VALUES (?, 'old-item', ?)", arguments: [session.rawValue, #"{"assistant":{"_0":{"content":"frozen legacy bytes"}}}"#])
    try db.execute(sql: "INSERT INTO session_pointers VALUES (?, 0, 0, 'old-item')", arguments: [session.rawValue])
  }
  try plant.close()
}

@Suite struct LegacyLinesTests {
  @Test func firstInputConvertsPointersOnceAndThenRunsOnLines() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let script = InferenceScript([
        { request in
          #expect(request.generation == 1)
          #expect(request.lines.contains { $0.key == "head:summary" && $0.text.contains("session_legacy_items WHERE session_id = '\(request.sessionID.rawValue)'") })
          #expect(request.lines.contains { $0.key == "message:m1" && $0.text.hasSuffix("\n\ncontinue") })
          #expect(!request.lines.contains { $0.text.contains("frozen legacy bytes") })
          return Fix.reply("continued")
        },
        Fix.replying("still working"),
      ])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let id = try await space.sessions.createSession(group: .shared, title: "legacy", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(space, id)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("continue"), to: id)
        try await until("legacy conversion and first reply") { try await space.sessions.settledWork(id) && script.count == 1 }
        try await service.enqueue(item: Fix.message("again", message: "m2"), to: id)
        try await until("the second reply") { try await space.sessions.settledWork(id) && script.count == 2 }
        #expect(try await space.sessions.generation(id) == 1)
        #expect(try await space.sessions.transcriptLines(id, generation: 0).isEmpty)
        #expect(try await space.query("SELECT payload FROM session_legacy_items WHERE session_id = ?", arguments: [.string(id.rawValue)], as: .shared(.anonymous)).rows == [[.text(#"{"assistant":{"_0":{"content":"frozen legacy bytes"}}}"#)]])
      }
    }
  }

  @Test(arguments: [false, true])
  func jobsFromAnOldLegacySlotFinishWithoutInferringAndTriggerOneConversion(compaction: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let prepared = Box(0)
      let script = InferenceScript([Fix.replying("recovered")])
      var config = makeConfig(inference: { request in
        #expect(request.generation == 1)
        #expect(request.lines.contains { $0.key == "head:summary" && $0.text.contains("earlier context was not converted") })
        return try await script(request)
      })
      config.prepareCompaction = { _, _, _ in prepared.withLock { $0 += 1 }; return nil }
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await space.sessions.createSession(group: .shared, title: "legacy in flight", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(space, id)
      try await runService(service) { _ in
        let slot = Slot(session: id, generation: 0, position: 7, stepTry: 0)
        try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.installTurn(position: 7) }
        if compaction {
          try space.worker.create(slot.compaction, params: .init(session: id, generation: 0, position: 7, kind: .pointer))
        } else {
          try space.worker.create(slot.step, params: .init(session: id, generation: 0, position: 7, ping: false))
        }
        try await until("the old job's look converts the legacy generation") { try await space.sessions.settledWork(id) && script.count == 1 }
        #expect(prepared.value == 1)
        #expect(try await space.sessions.generation(id) == 1)
        let address = compaction ? slot.compaction.description : slot.step.description
        #expect(try await space.writer.read { try String.fetchOne($0, sql: "SELECT phase FROM wuwei_job WHERE address = ?", arguments: [address]) } == "done")
        try await space.worker.call(SessionCell.ID(id.rawValue)) { cell in
          try cell.stepped(slot.step, StepResult(ending: .reply(AssistantEntry(Fix.reply("stale").message, id: UUID(), at: anchor, metadata: Fix.reply("stale").metadata, replayBinding: nil, mint: { .init("unused") }), fullness: 0, warming: nil), attempts: 1, waitedMs: 0))
        }
        #expect(try await space.sessions.lines(id).assistantLines.map(\.text) == ["recovered"])
        #expect(prepared.value == 1)
      }
    }
  }

  @Test func anOldCompactionAnswerAtTheLegacyRowSlotIsDroppedBeforeConversion() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let script = InferenceScript([Fix.replying("converted")])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let id = try await space.sessions.createSession(group: .shared, title: "old answer", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(space, id)
      try await runService(service) { _ in
        try await space.worker.call(SessionCell.ID(id.rawValue)) { cell in
          try cell.installTurn(position: 7)
          try cell.compacted(Slot(session: id, generation: 0, position: 7, stepTry: 0).compaction, .failed("stale compaction failure"))
        }
        try await until("the stale answer triggers conversion") { try await space.sessions.settledWork(id) && script.count == 1 }
        #expect(try await space.sessions.generation(id) == 1)
        #expect(try await space.sessions.record(id).errorMessage == nil)
      }
    }
  }

  @Test func aDrainedIdleLegacyPointerJobConvertsWhenTheNewWorkerRerunsIt() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("legacy-idle-pointer")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let script = InferenceScript([Fix.replying("converted")])
      let config = makeConfig(inference: { request in
        #expect(request.generation == 1)
        return try await script(request)
      })
      let first = SessionExecution(space: old, loopConfig: config)
      let id = try await old.sessions.createSession(group: .shared, title: "idle legacy pointer", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(old, id)
      first.start()
      try await old.worker.call(SessionCell.ID(id.rawValue)) { try $0.installTurn(position: 7, turn: .idle) }
      await first.shutdown()
      let slot = Slot(session: id, generation: 0, position: 7, stepTry: 0)
      let params = try JSONEncoder().encode(CompactionJob.Params(session: id, generation: 0, position: 7, kind: .pointer))
      try await old.writer.write { db in
        try db.execute(sql: "INSERT INTO wuwei_job (address, params) VALUES (?, ?)", arguments: [slot.compaction.description, params])
      }
      let new = try Space.open(file: file)
      try await runService(new, config) { _ in
        // The new worker's scan claims the legacy job (it has no lease row); the pointer compaction and the step after it are pokes.
        // One jump is enough for that claim; see `until` on a clock inside a poll.
        await time.advance(by: 2)
        try await until("the rerun pointer's look is consumed") {
          try await new.writer.read { db in
            try String.fetchOne(db, sql: "SELECT phase FROM wuwei_job WHERE address = ?", arguments: [slot.compaction.description]) == "done"
              && !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["SessionCell/" + id.rawValue])!
          }
        }
        try await until("the idle legacy slot opens its pointer generation") {
          let generation = try await new.sessions.generation(id)
          let settled = try await new.sessions.settledWork(id)
          return generation == 1 && settled && script.count == 1
        }
        #expect(try await new.sessions.record(id).errorMessage == nil)
      }
      #expect(script.count == 1)
      try await old.close()
      try await new.close()
    }
  }

  @Test func anIdleLegacySessionConvertsWhenItsOwedReplyNagIsDue() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let script = InferenceScript([
        Fix.replying("converted"),
        { request in
          #expect(request.generation == 1)
          #expect(request.lines.owedReplyReminders.count == 1)
          return Fix.reply("answering", calls: [.init(id: "answer", name: "send_message", arguments: .object([:]))])
        },
        Fix.replying("done"),
      ])
      let config = makeConfig(executeInvocation: { invocation in .sendMessage(.init(messageID: .init("reply"), conversationID: .init(invocation.sessionID.rawValue), n: 1)) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await space.sessions.createSession(group: .shared, title: "legacy nag", kind: .agent, createdBy: "morgan", model: .test)
      try await seedLegacyGeneration(space, id)
      let conversation = ConversationID(id.rawValue)
      let nags = NagState(settle: .init(owed: [conversation: .owed]))
      try await runService(service) { _ in
        try await space.worker.call(SessionCell.ID(id.rawValue)) { cell in
          try cell.installTurn(position: 7, turn: .idle, nags: nags)
          try cell.wake()
        }
        try await until("the due nag converts and is answered") { try await space.sessions.settledWork(id) && script.count == 3 }
        #expect(try await space.sessions.generation(id) == 1)
        #expect(try await space.sessions.lines(id).owedReplyReminders.count == 1)
      }
    }
  }

  @Test func completedCompactionWhoseAnswerWasLostRecoversThroughInterruptAndStartOver() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let script = InferenceScript([Fix.replying("fresh work")])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let id = try await space.sessions.createSession(group: .shared, title: "lost compaction answer", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.installTurn(position: 7) }
        let address = Slot(session: id, generation: 0, position: 7, stepTry: 0).compaction.description
        let params = try JSONEncoder().encode(CompactionJob.Params(session: id, generation: 0, position: 7, kind: .pointer))
        try await space.writer.write { db in
          try db.execute(sql: "INSERT INTO wuwei_job (address, params, phase) VALUES (?, ?, 'done')", arguments: [address, params])
        }
        try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.look() }
        #expect(script.count == 0)
        #expect(try await space.sessions.record(id).work == .hasWork)
        await #expect(throws: SessionStoreError.busyForRestart(id.rawValue)) {
          try await service.restart(id, executor: nil, note: nil)
        }
        try await service.interrupt(id)
        try await until("the interrupted hold") { try await space.sessions.record(id).hold == .interrupted }
        _ = try await service.restart(id, executor: nil, note: "Start over after a lost compaction answer.")
        try await until("the fresh inert generation") { try await space.sessions.generation(id) == 1 }
        try await service.enqueue(item: Fix.message("new input"), to: id)
        try await until("fresh work settles") { try await space.sessions.settledWork(id) && script.count == 1 }
        #expect(try await space.sessions.lines(id).assistantLines.map(\.text) == ["fresh work"])
        #expect(try await space.sessions.record(id).hold == .normal)
      }
    }
  }
}

private extension SessionCell {
  mutating func installTurn(position: Int, turn: SessionTurn.Turn = .model, nags: NagState = NagState()) throws {
    let turn = SessionTurn(generation: 0, position: position, turn: turn, reestablish: [], replied: false, nags: nags, seen: true, armed: true)
    try db.execute(SessionTurn.delete())
    try db.execute(SessionTurn.insert { turn })
    try rows.show(id.session, owed: turn.owed)
  }
}
