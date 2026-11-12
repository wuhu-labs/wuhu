import struct ControlledTime.TimeControl
import Dependencies
import DeterministicDependencies
import LoopCore
@testable import MainHub
@testable import SessionTools
@testable import SpaceServer
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Scratch
import SessionDomain
@testable import SpaceCore
import SpaceFS
import Testing

// Every notification the session was given, drained or not: a wake reaches its session cell at once, which may drain it.
/// Every notification the session was sent, seen by its model or not, once its cell has taken its mail.
func handlerNotifications(_ space: Space, _ session: SessionID) async throws -> [SystemNotification] {
  try await until("the session's cell takes its mail") {
    try await space.sessions.writer.read {
      try Bool.fetchOne($0, sql: "SELECT NOT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["\(SessionMail.kind)/\(session.rawValue)"])!
    }
  }
  return try await space.sessions.writer.read { try Sessions.undrained(session.rawValue, tail: 0, at: "9999", in: $0) }.compactMap {
    guard case let .notification(notification) = $0.input else { return nil }
    return notification
  }
}

func withHandlerFiring(
  _ space: Space,
  owner: Hub? = nil,
  sources: EventSources = .unavailable,
  _ body: (SessionExecution, Hub) async throws -> Void,
) async throws {
  let owner = owner ?? Hub(space: space)
  let worker = try await firingWorker(owner, sources: sources)
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await whenCancelled { await worker.shutdown() } }
    defer { group.cancelAll() }
    try await body(worker, owner)
  }
}

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct HandlerTests {
  @Test func oneObservationSerializesFiringsAcrossInFlightChanges() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let watched = try SpacePath(validating: "/input.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      _ = try await space.createTable(SpacePath(validating: "/runs.table"), header: .init(columns: [.init(name: "phase", type: .text)]), in: .shared, acting: .shared)
      _ = try await space.fs(.shared).write("/serial.js", Data("""
      import {mutateRows} from 'wuhu:space';
      export default async () => {
        await mutateRows('/runs.table',[{insert:{phase:'start'}}]);
        await sleep(5000);
        await mutateRows('/runs.table',[{insert:{phase:'end'}}]);
      };
      """.utf8), ifMatch: nil)
      let principal = try await space.principal(of: session)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("observe", .object(["sql": "SELECT n FROM \"/input.table\"", "throttle_seconds": 1, "handler": "/serial.js"]))
        _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await untilAdvancing("first firing started", time) { try await space.query("SELECT phase FROM \"/runs.table\"", as: principal).rows.count == 1 }
        _ = try await space.mutateRows(watched, [.insert([.integer(2)])], in: .shared, acting: .shared)
        try await untilAdvancing("second firing ended", time) {
          try await space.query("SELECT phase FROM \"/runs.table\"", as: principal).rows.count == 4
        }
        let phases = try await space.query("SELECT phase FROM \"/runs.table\" ORDER BY id", as: principal)
        #expect(phases.rows.map { $0[0] } == [.text("start"), .text("end"), .text("start"), .text("end")])
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }

  @Test func aSQLSlotsThrottleWaitsOnTheOwnersInjectedClock() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let input = try SpacePath(validating: "/throttle-input.table")
      let output = try SpacePath(validating: "/throttle-output.table")
      let header = TableHeader(columns: [.init(name: "n", type: .integer)])
      _ = try await space.createTable(input, header: header, in: .shared, acting: .shared)
      _ = try await space.createTable(output, header: header, in: .shared, acting: .shared)
      _ = try await space.fs(.shared).write("/throttle.js", Data("""
      import {mutateRows} from 'wuhu:space';
      export default async ({rows}) => { await mutateRows('/throttle-output.table', [{insert: {n: rows.at(-1).n}}]); };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        let stream = try space.observeRows("SELECT n FROM \"/throttle-output.table\" ORDER BY id", throttle: .zero, as: .shared(.anonymous))
        var snapshots = stream.makeAsyncIterator()
        #expect(try await snapshots.next()?.rows.isEmpty == true)
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("observe", .object(["sql": "SELECT n FROM \"/throttle-input.table\" ORDER BY n", "throttle_seconds": 10, "handler": "/throttle.js"]))
        _ = try await space.mutateRows(input, [.insert([.integer(1)])], in: .shared, acting: .shared)
        #expect(try await snapshots.next()?.rows == [[.integer(1)]])
        _ = try await space.mutateRows(input, [.insert([.integer(2)])], in: .shared, acting: .shared)
        try await time.asleep("the SQL slot's owner throttle", dueIn: 10)
        #expect(try await space.query("SELECT n FROM \"/throttle-output.table\"", as: .shared(.anonymous)).rows == [[.integer(1)]])
        await time.advance(by: 10)
        #expect(try await snapshots.next()?.rows == [[.integer(1)], [.integer(2)]])
      }
    }
  }

  @Test func archiveCancelsCPUHandlerAndArchivedFiringRetiresSlot() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/archive.js", Data("""
      import {writeText} from 'wuhu:space';
      export default async ({wake}) => {
        wake('discard'); await writeText('/archive-started.md','started',{ifMatch:null}); while(true) {}
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/archive.js"]))
        await time.advance(by: 2)
        try await untilAdvancing("archive handler started", time) { (try? await space.fs(.shared).stat("/archive-started.md")) != nil }
        _ = try await space.sessions.archive(session, grace: .seconds(100))
        try await untilAdvancing("archived pending timer retires", time) { try await space.sessions.armedSubscriptions(session).isEmpty }
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }

  @Test func archivedFiringsRetirePlainAndHandlerObserversAndTimersWithoutRunningOrWaking() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/must-not-run.js", Data("import {writeText} from 'wuhu:space'; export default async () => { await writeText('/ran.md','bad',{ifMatch:null}); wake('bad'); return null; };".utf8), ifMatch: nil)
      let watched = try SpacePath(validating: "/archived-input.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      _ = try await firingWorker(Hub(space: space))
      var world = ToolWorld(executor: try await SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      for handler in [false, true] {
        var timer: [String: JSONValue] = ["message": "bad", "in_seconds": 10]
        var observe: [String: JSONValue] = ["sql": "SELECT n FROM \"/archived-input.table\"", "throttle_seconds": 1]
        if handler { timer["handler"] = "/must-not-run.js"; observe["handler"] = "/must-not-run.js" }
        _ = try await world.run("timer", .object(.init(uniqueKeysWithValues: timer.sorted { $0.key < $1.key })))
        _ = try await world.run("observe", .object(.init(uniqueKeysWithValues: observe.sorted { $0.key < $1.key })))
      }
      try await until("the observers armed theirs") { try await space.sessions.armedSubscriptions(session).count == 3 }
      _ = try await space.sessions.archive(session, grace: .seconds(100))
      _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
      var notices: [SystemNotification] = []
      try await withHandlerFiring(space) { _, _ in
        await time.advance(by: 11)
        try await untilAdvancing("archived firings retire registrations", time) { try await space.sessions.armedSubscriptions(session).isEmpty }
        // Read while the worker still takes mail: the firing group quiesces it on the way out, and no cell takes mail then.
        notices = try await handlerNotifications(space, session)
      }
      #expect(notices.allSatisfy { $0.kind == .timer }, "only the plain timer's own input came due")
      #expect((try? await space.fs(.shared).stat("/ran.md")) == nil)
    }
  }

  @Test func interruptedTimerReopensAndReruns() async throws {
    let folder = try ScratchFolder("handler-runtime-restart")
    let file = folder.url.appending(path: "space.sqlite")
    try await withToolDeps { time in
      let first = try Space.open(file: file)
      let session = try await makeSession(first)
      _ = try await first.fs(.shared).write("/pending.js", Data("""
      import {writeText} from 'wuhu:space';
      export default async ({wake}) => {
        await writeText('/pending-started.md','started',{ifMatch:null});
        wake('not committed');
        await sleep(120000);
      }
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(first) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/pending.js"]))
        await time.advance(by: 2)
        try await untilTicking("pending timer began", time) { (try? await first.fs(.shared).stat("/pending-started.md")) != nil }
      }
      #expect(try await handlerNotifications(first, session).isEmpty)
      try await first.close()
      let reopened = try Space.open(file: file)
      let fs = await reopened.fs(.shared)
      let (token, _) = try await fs.read("/pending.js")
      _ = try await fs.write("/pending.js", Data("export default ({wake}) => { wake('resumed'); };".utf8), ifMatch: token)
      try await withHandlerFiring(reopened) { _, _ in
        try await untilTicking("reopened firing finishes", time) { try await reopened.sessions.armedSubscriptions(session).isEmpty }
        #expect(try await handlerNotifications(reopened, session).map { $0.content.text } == ["resumed"])
      }
      try await reopened.close()
    }
  }

  @Test func cancellationInterruptsCPUHandlerWithoutWake() async throws {
    try await withRig { rig in
      try await rig.write("/cpu.js", """
      import {writeText} from 'wuhu:space';
      export default async ({wake}) => {
        wake('discard on cancellation');
        await writeText('/started.md','started',{ifMatch:null});
        while(true) {}
      };
      """)
      let tools = try await SessionRuntime.toolExecutor(owner: Hub(space: rig.space))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          do { _ = try await rig.scripts.runHandler(path: "/cpu.js", actor: .session(rig.session), tools: tools) }
          catch is CancellationError { return }
        }
        try await until("CPU handler started") { (try? await rig.space.fs(.shared).stat("/started.md")) != nil }
        group.cancelAll()
      }
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
    }
  }

  @Test func handlerTimeoutDiscardsEarlyWake() async throws {
    try await withRig { rig in
      let tools = try await SessionRuntime.toolExecutor(owner: Hub(space: rig.space))
      try await rig.write("/timeout.js", "export default async ({wake}) => { wake('discard'); await sleep(120000); return 1; }")
      do {
        async let run = rig.scripts.runHandler(path: "/timeout.js", actor: .session(rig.session), tools: tools)
        try await rig.time.asleep("the handler's sleep", dueIn: 120)
        try await rig.time.wake("the handler's budget", after: 60)
        _ = try await run
        Issue.record("timeout succeeded")
      } catch { #expect(String(describing: error).contains("60")) }
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
    }
  }

  @Test func immediateMessagePostUsesExistingTargetsAndAuthorization() async throws {
    try await withRig { rig in
      try await rig.write("/post.js", """
      import {sendMessage} from 'wuhu:session';
      export default async () => { await sendMessage({message:'handler answered'}); };
      """)
      _ = try await rig.scripts.runHandler(path: "/post.js", actor: .session(rig.session), tools: try await SessionRuntime.toolExecutor(owner: Hub(space: rig.space)))
      let page = try await rig.evaluate("import {conversation} from 'wuhu:space'; result((await conversation(import.meta.session)).messages.map(m=>m.text));")
      #expect(page == .array(["handler answered"]))
      let refused = try await rig.evaluate("import {sendMessage} from 'wuhu:session'; try { await sendMessage({message:'wrong',user:'morgan'}); } catch(e) { result(e.message); }")
      #expect(refused.stringValue?.contains("unsupported options") == true)
    }
  }

  @Test func moduleGetsRowsRightsAndOnlyExplicitWake() async throws {
    try await withRig { rig in
      try await rig.write("/handler.js", """
      import { writeText } from 'wuhu:space';
      export default async ({ rows, wake }) => {
        await writeText('/handler-note.md', rows[0].text, {ifMatch:null});
        wake('release digest');
      }
      """)
      let rows = try await rig.space.query("SELECT 'release?' AS text", as: try await rig.space.principal(of: rig.session))
      let result = try await rig.scripts.runHandler(path: "/handler.js", actor: .session(rig.session), input: handlerInput(rows), tools: try await SessionRuntime.toolExecutor(owner: Hub(space: rig.space)))
      #expect(result.wakes == ["release digest"])
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
      #expect(String(decoding: try await rig.space.fs(.shared).read("/handler-note.md").1, as: UTF8.self) == "release?")
    }
  }

  @Test func thrownHandlerDiscardsBufferedWake() async throws {
    try await withRig { rig in
      try await rig.write("/throws.js", "export default ({wake}) => { wake('must not deliver'); throw Error('boom'); }")
      await #expect(throws: (any Error).self) {
        try await rig.scripts.runHandler(path: "/throws.js", actor: .session(rig.session), tools: try await SessionRuntime.toolExecutor(owner: Hub(space: rig.space)))
      }
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
    }
  }

  @Test func silentOneShotRetiresWithoutNotification() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/silent.js", Data("export default () => null;".utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 10, "handler": "/silent.js"]))
        try await until("its observer armed it") { try await space.sessions.armedSubscriptions(session).count == 1 }
        let queueHead = try await space.sessions.queueHead(session)
        await time.advance(by: 11)
        try await untilAdvancing("silent timer retires", time) { try await space.sessions.armedSubscriptions(session).isEmpty }
        #expect(try await space.sessions.hydrate(session).queueHead == queueHead)
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }

  @Test func cronRunsSilentlyAndRereadsEditedModule() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/tick.js", Data("import {writeText} from 'wuhu:space'; export default async ({subscription}) => { await writeText('/ticked.md',subscription,{ifMatch:null}); };".utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "cron": "* * * * *", "handler": "/tick.js"]))
        try await until("its observer armed it") { try await space.sessions.armedSubscriptions(session).count == 1 }
        let first = try await space.sessions.armedSubscriptions(session).first?.nextFireAt
        await time.advance(by: 61)
        // The firing is over once the slot is rescheduled: one still open when the next minute comes skips it.
        try await untilTicking("silent first tick", time) { try await space.sessions.armedSubscriptions(session).first?.nextFireAt != first }
        let slot = try await space.sessions.armedSubscriptions(session).first?.slot.id.rawValue
        #expect(String(decoding: try await fs.read("/ticked.md").1, as: UTF8.self) == slot)
        #expect(try await handlerNotifications(space, session).isEmpty)
        let (entry, _) = try await fs.read("/tick.js")
        _ = try await fs.write("/tick.js", Data("export default ({wake}) => { wake('edited tick'); };".utf8), ifMatch: entry)
        await time.advance(by: 61)
        try await untilTicking("edited handler wakes", time) {
          try await handlerNotifications(space, session).count == 1
        }
        #expect(try await handlerNotifications(space, session).map(\.content.text) == ["edited tick"])
        #expect(try await space.sessions.armedSubscriptions(session).first?.lastFiredAt != nil)
      }
    }
  }

  @Test func missingAndThrowingHandlerWakesOncePerStreakAndRecovers() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "cron": "* * * * *", "handler": "/missing.js"]))
        await time.advance(by: 61)
        try await untilTicking("missing handler error", time) { try await handlerNotifications(space, session).count == 1 }
        let missingError = try #require(await space.sessions.armedSubscriptions(session).first?.slot.lastError)
        #expect(missingError.contains("notFound:"), "\(missingError)")
        let fs = await space.fs(.shared)
        _ = try await fs.write("/missing.js", Data("export default () => { throw Error('again'); };".utf8), ifMatch: nil)
        try await untilTicking("same streak second error", time) {
          try await space.sessions.armedSubscriptions(session).first?.slot.lastError?.contains("again") == true
        }
        #expect(try await handlerNotifications(space, session).count == 1)
        let (entry, _) = try await fs.read("/missing.js")
        _ = try await fs.write("/missing.js", Data("export default () => {};".utf8), ifMatch: entry)
        try await untilTicking("success ends failure streak", time) { try await space.sessions.armedSubscriptions(session).first?.slot.lastError == nil }
        let (next, _) = try await fs.read("/missing.js")
        _ = try await fs.write("/missing.js", Data("export default () => { throw Error('new streak'); };".utf8), ifMatch: next)
        await time.advance(by: 61)
        try await untilTicking("new streak wakes again", time) { try await handlerNotifications(space, session).count == 2 }
      }
    }
  }
}

/// Time moves in hundredths of a second while the wait goes on: a jump leaves an evicted cell's wake to the worker's scan, which only a moving clock steps, and whole seconds per attempt would run a slow handler out of its minute.
private func untilTicking(_ description: String, _ time: TimeControl, _ condition: () async throws -> Bool) async throws {
  try await untilAdvancing(description, time, stepSeconds: 0.01, attempts: 6000, condition)
}

@Suite(.deterministicDependencies) struct ArchivedObservationTests {
  @Test(arguments: [false, true]) func archiveDoesNotRetireAnObserverWhoseSnapshotNeverChanges(handler: Bool) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/unchanged.js", Data("export default () => {};".utf8), ifMatch: nil)
      let owner = Hub(space: space)
      let worker = try await firingWorker(owner)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await whenCancelled { await worker.shutdown() } }
        defer { group.cancelAll() }
        var world = ToolWorld(worker: worker, session: session)
        var arguments: [String: JSONValue] = ["sql": "SELECT 1", "throttle_seconds": 1]
        if handler { arguments["handler"] = "/unchanged.js" }
        _ = try await world.run("observe", .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
        try await untilAdvancing("live observer starts", time) {
          try await space.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM observation_slots") == 1 }
        }
        _ = try await space.sessions.archive(session, grace: .seconds(100))
        try await holds("unchanged archived observer stays registered") { try await space.sessions.armedSubscriptions(session).count == 1 }
        try await space.sessions.unarchive(session)
        #expect(try await space.sessions.armedSubscriptions(session).count == 1, "unarchive before any query change must preserve the observer")
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }
}
