#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite struct SubscriptionQueryTests {
  @Test func queryShowsPublicSlotsWithHandlerMetadataNotInternalState() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let tests = SubscriptionHandlerTests()
      let id = try await tests.owner(store)
      let observation = try await tests.arm(store, id)
      _ = try await store.armSubscription(id, slot: .init(id: .init("timer"), kind: .timer(.cron("* * * * *"), message: "tick")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: .init("park"), kind: .parkReminder(request: .init("r"))))
      _ = try await store.armSubscription(id, slot: .init(id: .init("deadline"), kind: .requestDeadline(request: .init("r"), task: id)), nextFireAt: fixedDate)
      let initial = try await space.query("SELECT id, session_id, kind, sql, schedule, handler, armed_at, last_fired_at, last_error FROM subscriptions ORDER BY id")
      #expect(initial.rows == [
        [.text("timer"), .text(id.rawValue), .text("timer"), .null, .text("* * * * *"), .null, .text(SQLiteDateFormat.string(from: fixedDate)), .null, .null],
        [.text("watch"), .text(id.rawValue), .text("observe"), .text("SELECT 1"), .null, .text("/watch.js"), .text(SQLiteDateFormat.string(from: fixedDate)), .null, .null],
      ])
      _ = try await store.armSubscription(id, slot: .init(id: .init("once"), kind: .timer(.oneShot(fixedDate.addingTimeInterval(0.125)), message: "once")), nextFireAt: fixedDate.addingTimeInterval(60))
      #expect(try await space.query("SELECT schedule FROM subscriptions WHERE id = 'once'").rows == [[.text(SQLiteDateFormat.string(from: fixedDate.addingTimeInterval(0.125)))]])
      await #expect(throws: (any Error).self) { _ = try await space.query("SELECT payload FROM subscriptions") }
      let attempt = try await tests.begin(store, observation)
      _ = try await store.finishSubscriptionHandler(attempt, result: .failure(error: "module missing", notification: tests.wake(observation, "module missing")))
      #expect(try await space.query("SELECT last_fired_at, last_error FROM subscriptions WHERE id = 'watch'").rows == [[.text(SQLiteDateFormat.string(from: fixedDate)), .text("module missing")]])
      for sql in ["SELECT * FROM session_subscriptions", "SELECT * FROM main.session_subscriptions", "SELECT * FROM main.subscriptions"] {
        await #expect(throws: SpaceError.self) { _ = try await space.query(sql) }
      }
    }
  }

  @Test func subscriptionsMatchSessionVisibilityForGroupQualifiedWildcardAndSessionReaders() async throws {
    try await withSessionDeps {
      let space = try await GroupIsolationTests().seeded()
      let store = space.sessions
      let tests = SubscriptionHandlerTests()
      let shared = try await tests.owner(store)
      let alice = try await tests.owner(store, group: GroupIsolationTests.alice)
      let bob = try await tests.owner(store, group: GroupIsolationTests.bob)
      for id in [shared, alice, bob] { _ = try await tests.arm(store, id) }
      for principal in [
        Principal(actor: .anonymous, group: .shared),
        Principal(actor: .session(alice), group: GroupIsolationTests.alice),
        Principal(actor: .session(bob), group: GroupIsolationTests.bob),
      ] {
        let rows = try await space.query("SELECT session_id FROM subscriptions ORDER BY session_id", as: principal)
        let expected = principal.group == .shared ? shared : principal.group == GroupIsolationTests.alice ? alice : bob
        #expect(rows.rows == [[.text(expected.rawValue)]])
        let wildcard = try await space.query("SELECT grp, session_id FROM \"wuhu://*.localspace/subscriptions\" ORDER BY grp, session_id", as: principal)
        let sessions = try await space.query("SELECT grp, id FROM \"wuhu://*.localspace/sessions\" WHERE title = 'watch' ORDER BY grp, id", as: principal)
        #expect(wildcard.rows == sessions.rows)
      }
      let reader = Principal(actor: .session(alice), group: GroupIsolationTests.alice)
      #expect(try await space.query("SELECT session_id FROM \"wuhu://shared.localspace/subscriptions\"", as: reader).rows == [[.text(shared.rawValue)]])
      await #expect(throws: SpaceError.self) {
        _ = try await space.query("SELECT * FROM \"wuhu://bob.localspace/subscriptions\"", as: reader)
      }
      await #expect(throws: SpaceError.self) {
        _ = try await space.query("WITH subscriptions AS (SELECT * FROM main.session_subscriptions) SELECT * FROM subscriptions", as: reader)
      }
    }
  }

  @Test func observingSubscriptionsTracksArmingAttemptsFailuresAndCancellation() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let tests = SubscriptionHandlerTests()
      let id = try await tests.owner(space.sessions)
      let collected = Collector<Rows>()
      let stream = await space.observeQuery("SELECT id, last_fired_at, last_error FROM subscriptions", throttle: .zero)
      let task = Task { do { for try await rows in stream { await collected.append(rows) } } catch { Issue.record(error) } }
      defer { task.cancel() }
      _ = await awaitItems(collected, atLeast: 1)
      let slot = try await tests.arm(space.sessions, id)
      _ = await awaitItems(collected, atLeast: 2)
      let attempt = try await tests.begin(space.sessions, slot)
      _ = await awaitItems(collected, atLeast: 3)
      _ = try await space.sessions.finishSubscriptionHandler(attempt, result: .failure(error: "boom", notification: tests.wake(slot, "boom")))
      _ = await awaitItems(collected, atLeast: 4)
      try await space.sessions.cancelSubscription(id, subscriptionID: slot.slot.id)
      let snapshots = await awaitItems(collected, atLeast: 5)
      try #require(snapshots.count == 5)
      #expect(snapshots.first?.rows.isEmpty == true)
      #expect(snapshots[3].rows == [[.text("watch"), .text(SQLiteDateFormat.string(from: fixedDate)), .text("boom")]])
      #expect(snapshots.last?.rows.isEmpty == true)
    }
  }
}
