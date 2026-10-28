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
@_spi(SessionObservation) import SpaceCore
import SpaceFS
import Testing

func handlerNotifications(_ space: Space, _ session: SessionID) async throws -> [SystemNotification] {
  try await space.sessions.hydrate(session).undrained.compactMap {
    guard case let .notification(notification) = $0.input else { return nil }
    return notification
  }
}

func withHandlerFiring(
  _ space: Space,
  owner: Hub? = nil,
  configure: (inout SubscriptionFiring) -> Void = { _ in },
  _ body: (SessionExecution, Hub) async throws -> Void,
) async throws {
  let owner = owner ?? Hub(space: space)
  let (worker, registry) = await firingWorkers(owner)
  var configured = SubscriptionFiring(space: space, worker: registry)
  configure(&configured)
  let firing = configured
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await whenCancelled { await worker.shutdown() } }
    group.addTask { await firing.run() }
    defer { group.cancelAll() }
    try await body(worker, owner)
  }
}

@Suite(.deterministicDependencies) struct HandlerTests {
  @Test func oneObservationSerializesFiringsAcrossInFlightChanges() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let watched = try SpacePath(validating: "/input.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      _ = try await space.createTable(SpacePath(validating: "/runs.table"), header: .init(columns: [.init(name: "phase", type: .text)]), in: .shared, acting: .shared)
      _ = try await space.fs(.shared).write("/serial.js", Data("""
      import {mutateRows} from 'wuhu:space';
      export default async ({state}) => {
        await mutateRows('/runs.table',[{insert:{phase:'start'}}]);
        await sleep(5000);
        await mutateRows('/runs.table',[{insert:{phase:'end'}}]);
        return {n:(state?.n??0)+1};
      };
      """.utf8), ifMatch: nil)
      let principal = try await space.principal(of: session)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("observe", .object(["sql": "SELECT n FROM \"/input.table\"", "throttle_seconds": 1, "handler": "/serial.js"]))
        _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
        try await untilAdvancing("first firing started", time) { try await space.query("SELECT phase FROM \"/runs.table\"", as: principal).rows.count == 1 }
        _ = try await space.mutateRows(watched, [.insert([.integer(2)])], in: .shared, acting: .shared)
        try await untilAdvancing("second firing saved", time) {
          let json = try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON
          return json.flatMap(JSONValue.parse)?.object?["n"] == .integer(2)
        }
        let phases = try await space.query("SELECT phase FROM \"/runs.table\" ORDER BY id", as: principal)
        #expect(phases.rows.map { $0[0] } == [.text("start"), .text("end"), .text("start"), .text("end")])
        #expect(try await handlerNotifications(space, session).isEmpty)
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
      }
      #expect(try await handlerNotifications(space, session).isEmpty)
    }
  }

  @Test func archivedFiringsRetirePlainAndHandlerObserversAndTimersWithoutRunningOrWaking() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/must-not-run.js", Data("import {writeText} from 'wuhu:space'; export default async () => { await writeText('/ran.md','bad',{ifMatch:null}); wake('bad'); return null; };".utf8), ifMatch: nil)
      let watched = try SpacePath(validating: "/archived-input.table")
      _ = try await space.createTable(watched, header: .init(columns: [.init(name: "n", type: .integer)]), in: .shared, acting: .shared)
      var world = ToolWorld(executor: SessionRuntime.toolExecutor(owner: Hub(space: space)), session: session)
      for handler in [false, true] {
        var timer: [String: JSONValue] = ["message": "bad", "in_seconds": 10]
        var observe: [String: JSONValue] = ["sql": "SELECT n FROM \"/archived-input.table\"", "throttle_seconds": 1]
        if handler { timer["handler"] = "/must-not-run.js"; observe["handler"] = "/must-not-run.js" }
        _ = try await world.run("timer", .object(.init(uniqueKeysWithValues: timer.sorted { $0.key < $1.key })))
        _ = try await world.run("observe", .object(.init(uniqueKeysWithValues: observe.sorted { $0.key < $1.key })))
      }
      _ = try await space.sessions.archive(session, grace: .seconds(100))
      #expect(try await space.sessions.armedSubscriptions(session).count == 4)
      let head = try await space.sessions.queueHead(session)
      _ = try await space.mutateRows(watched, [.insert([.integer(1)])], in: .shared, acting: .shared)
      try await withHandlerFiring(space) { _, _ in
        await time.advance(by: 11)
        try await untilAdvancing("archived firings retire registrations", time) { try await space.sessions.armedSubscriptions(session).isEmpty }
      }
      #expect(try await handlerNotifications(space, session).isEmpty)
      #expect(try await space.sessions.queueHead(session) == head)
      #expect((try? await space.fs(.shared).stat("/ran.md")) == nil)
    }
  }

  @Test func interruptedTimerReopensAndRerunsLastSavedState() async throws {
    let folder = try ScratchFolder("handler-runtime-restart")
    let file = folder.url.appending(path: "space.sqlite")
    try await withToolDeps { time in
      var first: Space? = try Space.open(file: file)
      let session = try await makeSession(try #require(first))
      _ = try await #require(first).fs(.shared).write("/pending.js", Data("""
      import {writeText} from 'wuhu:space';
      export default async ({state,wake}) => {
        await writeText('/pending-started.md','started',{ifMatch:null});
        wake('not committed');
        await sleep(120000);
        return {cursor:99};
      }
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(try #require(first)) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/pending.js"]))
        await time.advance(by: 2)
        try await untilAdvancing("pending timer began", time) { (try? await first?.fs(.shared).stat("/pending-started.md")) != nil }
      }
      let savedState = try await #require(first).sessions.armedSubscriptions(session).first?.slot.handlerStateJSON
      let notifications = try await handlerNotifications(try #require(first), session)
      #expect(savedState == nil)
      #expect(notifications.isEmpty)
      first = nil
      let reopened = try Space.open(file: file)
      let fs = await reopened.fs(.shared)
      let (token, _) = try await fs.read("/pending.js")
      _ = try await fs.write("/pending.js", Data("export default ({state,wake}) => { if(state!==null) throw Error('advanced prematurely'); wake('resumed'); return {cursor:1}; };".utf8), ifMatch: token)
      try await withHandlerFiring(reopened) { _, _ in
        try await untilAdvancing("reopened firing finishes", time) { try await reopened.sessions.armedSubscriptions(session).isEmpty }
        #expect(try await handlerNotifications(reopened, session).map { $0.content.text } == ["resumed"])
      }
    }
  }

  @Test func cancellationInterruptsCPUHandlerWithoutWakeOrStateCommit() async throws {
    try await withRig { rig in
      try await rig.write("/cpu.js", """
      import {writeText} from 'wuhu:space';
      export default async ({wake}) => {
        wake('discard on cancellation');
        await writeText('/started.md','started',{ifMatch:null});
        while(true) {}
      };
      """)
      let tools = SessionRuntime.toolExecutor(owner: Hub(space: rig.space), scripts: rig.scripts)
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

  @Test func handlerTimeoutDiscardsEarlyWakeAndRejectsUndefinedOrOversizeState() async throws {
    try await withRig { rig in
      let tools = SessionRuntime.toolExecutor(owner: Hub(space: rig.space), scripts: rig.scripts)
      try await rig.write("/timeout.js", "export default async ({wake}) => { wake('discard'); await sleep(120000); return 1; }")
      do {
        _ = try await rig.advancing {
          try await rig.scripts.runHandler(path: "/timeout.js", actor: .session(rig.session), tools: tools)
        }
        Issue.record("timeout succeeded")
      } catch { #expect(String(describing: error).contains("60")) }
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
      try await rig.write("/undefined.js", "export default () => undefined;")
      try await rig.write("/oversize.js", "export default () => 'x'.repeat(20000);")
      for path in ["/undefined.js", "/oversize.js"] {
        await #expect(throws: (any Error).self) { try await rig.scripts.runHandler(path: path, actor: .session(rig.session), tools: tools) }
      }
    }
  }

  @Test func immediateMessagePostUsesExistingTargetsAndAuthorization() async throws {
    try await withRig { rig in
      try await rig.write("/post.js", """
      import {sendMessage} from 'wuhu:session';
      export default async () => { return await sendMessage({message:'handler answered'}); };
      """)
      let result = try await rig.scripts.runHandler(path: "/post.js", actor: .session(rig.session), tools: SessionRuntime.toolExecutor(owner: Hub(space: rig.space)))
      let posted = try #require(JSONValue.parse(result.stateJSON)?.object)
      #expect(posted["conversationId"] == .string(rig.session.rawValue))
      let page = try await rig.evaluate("import {conversation} from 'wuhu:space'; result((await conversation(import.meta.session)).messages.map(m=>m.text));")
      #expect(page == .array(["handler answered"]))
      let refused = try await rig.evaluate("import {sendMessage} from 'wuhu:session'; try { await sendMessage({message:'wrong',user:'morgan'}); } catch(e) { result(e.message); }")
      #expect(refused.stringValue?.contains("unsupported options") == true)
    }
  }

  @Test func channelCursorSkipsTenPlainMessagesAndResumesWithoutRepeating() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let channel = try await space.sessions.createConversation(members: ["morgan"], title: "The Park", in: .shared)
      _ = try await space.fs(.shared).write("/park.js", Data("""
      export default ({rows,state,wake}) => {
        const fresh = rows.filter(row => row.n > (state?.cursor ?? 0));
        if (fresh.some(row => row.text.includes('release'))) wake('Release question\\nDecision needed');
        return {cursor:Math.max(state?.cursor ?? 0,...fresh.map(row=>row.n))};
      }
      """.utf8), ifMatch: nil)
      func post(_ n: Int, _ text: String) async throws {
        _ = try await space.sessions.post(.conversation(channel), messageID: .init("park-\(n)"), sender: .init(id: "morgan", timeZone: TimeZone(identifier: "UTC")!), content: .init(text: text))
      }
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("observe", .object([
          "sql": .string("SELECT n, json_extract(content,'$.text') AS text FROM messages WHERE conversation_id = '\(channel.rawValue)' ORDER BY n"),
          "throttle_seconds": 1, "handler": "/park.js",
        ]))
        for n in 1 ... 10 {
          try await post(n, "plain \(n)")
          try await untilAdvancing("plain cursor \(n)", time) {
            let json = try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON
            return json.flatMap(JSONValue.parse)?.object?["cursor"] == .integer(n)
          }
        }
        #expect(try await handlerNotifications(space, session).isEmpty)
        try await post(11, "Should we release today?")
        try await untilAdvancing("one relevant wake", time) { try await handlerNotifications(space, session).count == 1 }
        #expect(try await handlerNotifications(space, session).first?.content.text == "Release question\nDecision needed")
      }
      try await post(12, "plain while stopped")
      try await withHandlerFiring(space) { _, _ in
        try await untilAdvancing("cursor resumes", time) {
          let json = try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON
          return json.flatMap(JSONValue.parse)?.object?["cursor"] == .integer(12)
        }
        #expect(try await handlerNotifications(space, session).count == 1)
        try await post(13, "release decision again")
        try await untilAdvancing("next relevant wake", time) { try await handlerNotifications(space, session).count == 2 }
      }
    }
  }

  @Test func moduleGetsStateRowsRightsAndOnlyExplicitWake() async throws {
    try await withRig { rig in
      try await rig.write("/handler.js", """
      import { writeText } from 'wuhu:space';
      export default async ({ rows, state, wake }) => {
        await writeText('/handler-note.md', rows[0].text, {ifMatch:null});
        wake('release digest');
        return {cursor: (state?.cursor ?? 0) + rows.length};
      }
      """)
      let rows = try await rig.space.query("SELECT 'release?' AS text", as: try await rig.space.principal(of: rig.session))
      let result = try await rig.scripts.runHandler(path: "/handler.js", actor: .session(rig.session), input: .rows(rows), stateJSON: "{\"cursor\":10}", tools: SessionRuntime.toolExecutor(owner: Hub(space: rig.space), scripts: rig.scripts))
      #expect(JSONValue.parse(result.stateJSON) == .object(["cursor": 11]))
      #expect(result.wakes == ["release digest"])
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
      #expect(String(decoding: try await rig.space.fs(.shared).read("/handler-note.md").1, as: UTF8.self) == "release?")
    }
  }

  @Test func thrownHandlerDiscardsBufferedWakeAndState() async throws {
    try await withRig { rig in
      try await rig.write("/throws.js", "export default ({wake}) => { wake('must not deliver'); throw Error('boom'); }")
      await #expect(throws: (any Error).self) {
        try await rig.scripts.runHandler(path: "/throws.js", actor: .session(rig.session), tools: SessionRuntime.toolExecutor(owner: Hub(space: rig.space)))
      }
      #expect(try await handlerNotifications(rig.space, rig.session).isEmpty)
    }
  }

  @Test func silentOneShotRetiresWithoutNotificationAndHydrationDropsFoldedTimer() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/silent.js", Data("export default () => null;".utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 10, "handler": "/silent.js"]))
        _ = try await space.sessions.writeCompaction(session, head: .init(
          id: UUID(), timestamp: anchor, summary: "waiting for quiet timer", snapshot: .init(subscriptions: world.state.subscriptions),
          runningWork: [],
        ), kept: nil)
        let before = try await space.sessions.transcript(session)
        #expect(!before.environment.tools.subscriptions.isEmpty)
        let queueHead = try await space.sessions.queueHead(session)
        await time.advance(by: 11)
        try await untilAdvancing("silent timer retires", time) { try await space.sessions.armedSubscriptions(session).isEmpty }
        let hydration = try await space.sessions.hydrate(session)
        guard case let .kernel(transcript) = hydration.transcript else { Issue.record("expected kernel transcript"); return }
        #expect(transcript.environment.tools.subscriptions.isEmpty)
        #expect(hydration.queueHead == queueHead)
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }

  @Test func cronRunsSilentlyAndRereadsEditedModule() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/tick.js", Data("export default ({state, fireTime}) => ({n:(state?.n ?? 0)+1, fireTime});".utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, owner in
        var world = ToolWorld(worker: worker, session: session)
        _ = try await world.run("timer", .object(["message": "unused", "cron": "* * * * *", "handler": "/tick.js"]))
        await time.advance(by: 61)
        try await untilAdvancing("silent first tick", time) {
          try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON != nil
        }
        #expect(try await handlerNotifications(space, session).isEmpty)
        let (entry, _) = try await fs.read("/tick.js")
        _ = try await fs.write("/tick.js", Data("export default ({state,wake}) => { wake('edited tick'); return {n:state.n+1}; };".utf8), ifMatch: entry)
        await time.advance(by: 61)
        try await untilAdvancing("edited handler wakes", time) {
          try await handlerNotifications(space, session).count == 1
        }
        #expect(try await handlerNotifications(space, session).first?.content.text == "edited tick")
        let slot = try #require(await space.sessions.armedSubscriptions(session).first)
        #expect(JSONValue.parse(try #require(slot.slot.handlerStateJSON)) == .object(["n": 2]))
        #expect(slot.lastFiredAt != nil)
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
        try await time.wake("first cron firing", after: 60)
        try await until("missing handler error") { try await handlerNotifications(space, session).count == 1 }
        let missingError = try #require(await space.sessions.armedSubscriptions(session).first?.slot.lastError)
        #expect(missingError.contains("notFound:"), "\(missingError)")
        let fs = await space.fs(.shared)
        _ = try await fs.write("/missing.js", Data("export default () => { throw Error('again'); };".utf8), ifMatch: nil)
        try await time.wake("first retry", after: 1)
        try await until("same streak second error") {
          try await space.sessions.armedSubscriptions(session).first?.slot.lastError?.contains("again") == true
        }
        #expect(try await handlerNotifications(space, session).count == 1)
        let (entry, _) = try await fs.read("/missing.js")
        _ = try await fs.write("/missing.js", Data("export default ({state}) => ({n:(state?.n ?? 0)+1});".utf8), ifMatch: entry)
        try await time.wake("second retry", after: 2)
        try await until("success ends failure streak") { try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON != nil }
        #expect(try await space.sessions.armedSubscriptions(session).first?.slot.lastError == nil)
        let (next, _) = try await fs.read("/missing.js")
        _ = try await fs.write("/missing.js", Data("export default () => { throw Error('new streak'); };".utf8), ifMatch: next)
        @Dependency(\.date) var date
        let nextFire = try #require(await space.sessions.armedSubscriptions(session).first?.nextFireAt)
        try await time.wake("next cron firing", after: nextFire.timeIntervalSince(date.now))
        try await until("new streak wakes again") { try await handlerNotifications(space, session).count == 2 }
        #expect(JSONValue.parse(try #require(await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON)) == .object(["n": 1]))
      }
    }
  }
}

@Suite(.deterministicDependencies) struct ArchivedObservationTests {
  @Test(arguments: [false, true]) func archiveDoesNotRetireAnObserverWhoseSnapshotNeverChanges(handler: Bool) async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/unchanged.js", Data("export default ({state}) => state;".utf8), ifMatch: nil)
      let owner = Hub(space: space)
      let worker = await firingWorker(owner)
      let streams = Box(0)
      var firing = SubscriptionFiring(space: space, worker: worker)
      firing.observationStream = { space, principal, sql in
        streams.withLock { $0 += 1 }
        return await space.observeQuery(sql, throttle: .zero, as: principal)
      }
      let runner = firing
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await whenCancelled { await worker.shutdown() } }
        group.addTask { await runner.run() }
        defer { group.cancelAll() }
        var world = ToolWorld(worker: worker, session: session)
        var arguments: [String: JSONValue] = ["sql": "SELECT 1", "throttle_seconds": 1]
        if handler { arguments["handler"] = "/unchanged.js" }
        _ = try await world.run("observe", .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
        try await untilAdvancing("live observer starts", time) { streams.value == 1 }
        _ = try await space.sessions.archive(session, grace: .seconds(100))
        try await untilAdvancing("runtime handles archive change", time) { streams.value == 2 }
        try await holds("unchanged archived observer stays registered") { try await space.sessions.armedSubscriptions(session).count == 1 }
        try await space.sessions.unarchive(session)
        try await untilAdvancing("runtime resumes retained observer", time) { streams.value == 3 }
        #expect(try await space.sessions.armedSubscriptions(session).count == 1, "unarchive before any query change must preserve the observer")
        #expect(try await handlerNotifications(space, session).isEmpty)
      }
    }
  }
}
