import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import MainHub
import SessionDomain
import struct SpaceContract.ObserverInput
import struct SpaceContract.ObserverTimerInput
import struct SpaceContract.SubscriptionObserveInput
@_spi(SessionObservation) import SpaceCore
import Testing

// A group's observer through the real firing loop and main's API: it acts as
// its group, stamps what it makes with its firing, and a failed firing
// reruns the same input.
@Suite(.deterministicDependencies) struct GroupObserverTests {
  @Test func observerActsAsItsGroupStampsWhatItMakesAndRetriesTheSameFireTime() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let alice = try await space.addAccount(kind: .human, name: "alice")
      let foreign = try await space.createGroup(alias: "research", owner: alice.id)
      #expect(try await space.writes(.shared, in: foreign))
      _ = try await space.fs(.shared).write("/triage.js", Data("""
      import { readText, writeText } from 'wuhu:space';
      import { createSession } from 'wuhu:session';
      export default async ({ fireTime }) => {
        let first = false;
        try { await readText('/first.md'); } catch { first = true; }
        if (first) { await writeText('/first.md', String(fireTime), { ifMatch: null }); throw Error('first try'); }
        let outside = 'written';
        try { await writeText('wuhu://\(foreign.rawValue).localspace/x.md', 'x', { ifMatch: null }); } catch (e) { outside = e.code ?? String(e); }
        const made = await createSession({ title: 'made by triage', provider: 'testing', model: 'test-model' });
        await writeText('/result.json', JSON.stringify({ fireTime: String(fireTime), outside, made: made.id }), { ifMatch: null });
        return null;
      };
      """.utf8), ifMatch: nil)
      let owner = Hub(space: space, resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      })
      let principal = try await space.principal(of: session)
      try await withHandlerFiring(space, owner: owner) { _, owner in
        let armed = try await owner.armObserver(.shared, ObserverInput(
          name: "triage", handler: "/triage.js", observe: nil, timer: ObserverTimerInput(inSeconds: 10, cron: nil), sessionsPerHour: nil,
        ))
        #expect(armed.owner == .group(.shared))
        await time.advance(by: 11)
        try await untilAdvancing("the retried firing writes its result", time) {
          (try? await space.fs(.shared).read("/result.json")) != nil
        }
        let first = String(decoding: try await space.fs(.shared).read("/first.md").1, as: UTF8.self)
        let result = try #require(JSONValue.parse(String(decoding: try await space.fs(.shared).read("/result.json").1, as: UTF8.self))?.object)
        #expect(result["fireTime"] == .string(first))
        #expect(result["outside"] != "written")
        await #expect(throws: (any Error).self) { _ = try await space.fs(foreign).read("/x.md") }

        let made = try SessionID(#require(result["made"]?.stringValue))
        let record = try await space.sessions.record(made)
        #expect(record.group == .shared)
        #expect(record.createdBy == "triage@shared")
        let firings = try await space.query(
          "SELECT id, name, outcome, error, effects FROM subscription_firings ORDER BY at, outcome", as: principal,
        ).rows
        #expect(firings.count == 2)
        #expect(firings.map { $0[2] } == [.text("failed"), .text("ok")])
        #expect(firings.allSatisfy { $0[1] == .text("triage") })
        guard case let .text(error) = firings[0][3] else { Issue.record("the failed firing logs its error"); return }
        #expect(error.contains("first try"))
        guard case let .text(raw) = firings[1][4], let effects = JSONValue.parse(raw)?.object else { Issue.record("the ok firing logs its effects"); return }
        #expect(effects["sessions"] == [.string(made.rawValue)])
        #expect(effects["revisions"]?.array?.isEmpty == false)
        let stamped = try await space.query("SELECT firing FROM sessions WHERE id = ?", arguments: [.string(made.rawValue)], as: principal).rows
        #expect(stamped == [[firings[1][0]]])
        #expect(try await space.sessions.observers(.shared).isEmpty)
      }
    }
  }

  @Test func everyWriteAHandlerMakesIsAttributedToItsFiring() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      _ = try await space.fs(.shared).write("/N.md", Data("---\ntemplate: {\"strategy\":\"incr\",\"prefix\":\"N\",\"pad\":3}\n---\nn".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/writes.js", Data("""
      import { writeText, writeBytes, createTable, tableSchema, alterTable, mutateRows, readAttributes, patchAttributes, instantiateTemplate, checkout, move, remove } from 'wuhu:space';
      export default async () => {
        const first = await writeText('/notes.md', '---\\na: 1\\n---\\nx', { ifMatch: null });
        await writeBytes('/raw.bin', new Uint8Array([1, 2]), { ifMatch: null });
        await createTable('/t.table', { columns: [{ name: 'a', type: 'string' }] });
        const { header, token } = await tableSchema('/t.table');
        await alterTable('/t.table', { columns: [...header.columns, { name: 'b', type: 'integer' }] }, { ifMatch: token });
        await mutateRows('/t.table', [{ insert: { a: 'x', b: 1 } }]);
        const patched = await patchAttributes('/notes.md', { set: { b: 2 }, ifMatch: (await readAttributes('/notes.md')).token });
        await instantiateTemplate('/N.md');
        await checkout('/notes.md', first.rev, { ifMatch: patched.token });
        await move('/raw.bin', '/moved.bin');
        await remove('/moved.bin');
        return null;
      };
      """.utf8), ifMatch: nil)
      let before = try await space.currentRevision()
      try await withHandlerFiring(space) { _, owner in
        _ = try await owner.armObserver(.shared, ObserverInput(
          name: "writes", handler: "/writes.js", observe: nil, timer: ObserverTimerInput(inSeconds: 1, cron: nil), sessionsPerHour: nil,
        ))
        try await untilAdvancing("the firing ends", time) {
          try await space.query("SELECT 1 FROM subscription_firings WHERE outcome <> 'running'", as: space.principal(of: session)).rows.count == 1
        }
        let firing = try await space.query("SELECT outcome, error, effects FROM subscription_firings", as: space.principal(of: session)).rows
        #expect(firing.first?[0] == .text("ok"), "\(firing)")
        let after = try await space.currentRevision()
        #expect(after - before == 10)
        guard case let .text(raw)? = firing.first?[2], let revisions = JSONValue.parse(raw)?.object?["revisions"]?.array else {
          Issue.record("the firing logs its revisions"); return
        }
        #expect(Set(revisions.compactMap(\.stringValue)) == Set((before + 1 ... after).map(String.init)))
      }
    }
  }

  @Test func cancellingAnObserverStopsItsFiringInFlight() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/slow.js", Data("""
      import { writeText } from 'wuhu:space';
      export default async () => {
        await writeText('/started.md', 'x', { ifMatch: null });
        await sleep(5000);
        await writeText('/after.md', 'x', { ifMatch: null });
        return null;
      };
      """.utf8), ifMatch: nil)
      try await withHandlerFiring(space) { _, owner in
        _ = try await owner.armObserver(.shared, ObserverInput(
          name: "slow", handler: "/slow.js", observe: nil, timer: ObserverTimerInput(inSeconds: 1, cron: nil), sessionsPerHour: nil,
        ))
        await time.advance(by: 2)
        try await until("the firing starts") { (try? await space.fs(.shared).read("/started.md")) != nil }
        _ = try await owner.cancelObserver(.shared, name: "slow")
        await time.advance(by: 10)
        try await holds("the cancelled firing writes nothing more") { (try? await space.fs(.shared).read("/after.md")) == nil }
      }
    }
  }

  @Test func observationThatTurnsInvalidPausesTheObserverWithItsError() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/watch.js", Data("export default ({state}) => state;".utf8), ifMatch: nil)
      try await withHandlerFiring(space, configure: { firing in
        firing.observationStream = { _, _, _ in
          AsyncThrowingStream { $0.finish(throwing: SpaceError.unknownRelation("/gone.table")) }
        }
      }) { _, owner in
        _ = try await owner.armObserver(.shared, ObserverInput(
          name: "watch", handler: "/watch.js", observe: SubscriptionObserveInput(sql: "SELECT 1", throttleSeconds: nil), timer: nil, sessionsPerHour: nil,
        ))
        try await untilAdvancing("the observer pauses", time) {
          try await space.sessions.observers(.shared).first?.status == .paused
        }
        let paused = try #require(try await space.sessions.observers(.shared).first)
        #expect(paused.slot.lastError?.contains("/gone.table") == true)
      }
    }
  }
}
