import DeterministicDependencies
@testable import MainHub
@testable import SessionTools
@testable import SpaceServer
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@_spi(SessionObservation) import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies) struct HandlerSelfCancelTests {
  func outcomes(_ space: Space, _ session: SessionID) async throws -> [[Cell]] {
    try await space.query("SELECT outcome FROM subscription_firings ORDER BY at, id", as: space.principal(of: session)).rows
  }

  @Test func aHandlerCancellingItsOwnTimerFinishesItsFiringWithItsWakes() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/self.js", Data("""
      import {readText} from 'wuhu:space';
      import {cancel} from 'wuhu:session';
      export default async ({wake}) => {
        wake('before');
        await cancel((await readText('/self-id.md')).content.trim());
        wake('after');
        return {n: 1};
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        var world = ToolWorld(worker: worker, session: session)
        guard case let .timer(timer) = try await world.run("timer", .object(["message": "unused", "cron": "* * * * *", "handler": "/self.js"])) else {
          Issue.record("expected a timer"); return
        }
        _ = try await fs.write("/self-id.md", Data(timer.subscriptionID.rawValue.utf8), ifMatch: nil)
        await time.advance(by: 61)
        try await untilAdvancing("self-cancelled firing ends", time) {
          let ended = try await outcomes(space, session)
          return !ended.isEmpty && ended != [[.text("running")]]
        }
        let firings = try await space.query("SELECT outcome, error FROM subscription_firings", as: space.principal(of: session)).rows
        #expect(firings == [[.text("ok"), .null]], "\(firings)")
        #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
        let woken = try await handlerNotifications(space, session)
        #expect(woken.map(\.content.text) == ["before", "after"])
        #expect(woken.map(\.endsSubscription) == [true, true])
        #expect(try failure(try await world.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)]))).code == "notFound")
      }
    }
  }

  @Test func aToolCancelDuringAFiringLetsItFinish() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/slow.js", Data("""
      import {readText, writeText} from 'wuhu:space';
      export default async ({wake}) => {
        await writeText('/slow-started.md', 'started', {ifMatch: null});
        for (;;) { try { await readText('/release.md'); break; } catch { await sleep(10); } }
        wake('finished');
        return {n: 1};
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        var world = ToolWorld(worker: worker, session: session)
        guard case let .timer(timer) = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/slow.js"])) else {
          Issue.record("expected a timer"); return
        }
        await time.advance(by: 2)
        try await untilAdvancing("slow handler started", time) { (try? await fs.stat("/slow-started.md")) != nil }
        guard case .cancelTimer = try await world.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)])) else { Issue.record("expected the cancel to succeed"); return }
        #expect(try failure(try await world.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)]))).code == "notFound")
        #expect(try await space.query("SELECT id FROM subscriptions", as: space.principal(of: session)).rows.isEmpty)
        _ = try await fs.write("/release.md", Data("go".utf8), ifMatch: nil)
        try await untilAdvancing("cancelled firing ends", time) { try await outcomes(space, session) == [[.text("ok")]] }
        #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
        #expect(try await handlerNotifications(space, session).map(\.content.text) == ["finished"])
      }
    }
  }

  @Test func aSelfCancelledFiringThatTimesOutEndsFailedWithoutItsWakes() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/stuck.js", Data("""
      import {readText} from 'wuhu:space';
      import {cancel} from 'wuhu:session';
      export default async ({wake}) => {
        wake('dropped');
        await cancel((await readText('/stuck-id.md')).content.trim());
        await sleep(120000);
        return {n: 1};
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        var world = ToolWorld(worker: worker, session: session)
        guard case let .timer(timer) = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/stuck.js"])) else {
          Issue.record("expected a timer"); return
        }
        _ = try await fs.write("/stuck-id.md", Data(timer.subscriptionID.rawValue.utf8), ifMatch: nil)
        await time.advance(by: 2)
        try await untilAdvancing("timed-out firing ends", time) {
          let ended = try await outcomes(space, session)
          return !ended.isEmpty && ended != [[.text("running")]]
        }
        #expect(try await outcomes(space, session) == [[.text("failed")]])
        #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
        let woken = try await handlerNotifications(space, session)
        #expect(!woken.map(\.content.text).contains("dropped"))
        #expect(woken.map(\.endsSubscription) == [true])
      }
    }
  }

  @Test func aRetiringSlotCutOffWithItsRegistryDoesNotComeBack() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let fs = await space.fs(.shared)
      _ = try await fs.write("/held.js", Data("""
      import {readText, writeText} from 'wuhu:space';
      export default async ({wake}) => {
        await writeText('/held-started.md', 'started', {ifMatch: null});
        for (;;) { try { await readText('/never.md'); break; } catch { await sleep(10); } }
        wake('never');
        return {n: 1};
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { worker, _ in
        var world = ToolWorld(worker: worker, session: session)
        guard case let .timer(timer) = try await world.run("timer", .object(["message": "unused", "cron": "* * * * *", "handler": "/held.js"])) else {
          Issue.record("expected a timer"); return
        }
        await time.advance(by: 61)
        try await untilAdvancing("held handler started", time) { (try? await fs.stat("/held-started.md")) != nil }
        guard case .cancelTimer = try await world.run("cancel", .object(["id": .string(timer.subscriptionID.rawValue)])) else {
          Issue.record("expected the cancel to succeed"); return
        }
      }
      let ended = try await outcomes(space, session)
      #expect(ended.count == 1 && ended != [[.text("running")]], "\(ended)")
      #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
      try await withHandlerFiring(space) { _, _ in
        await time.advance(by: 120)
        try await holds("no firing after restart") { try await outcomes(space, session).count == 1 }
      }
      #expect(try await space.sessions.armedSubscriptions(session).isEmpty)
      #expect(try await handlerNotifications(space, session).allSatisfy { $0.content.text != "never" })
    }
  }
}
