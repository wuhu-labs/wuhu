import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
import SessionDomain
@_spi(SessionObservation) @testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SubscriptionReconciliationTests {
  @Test(arguments: [false, true])
  func archiveAndUnarchivePreserveUnfiredPlainAndHandlerTimers(handler: Bool) async throws {
    let folder = try ScratchFolder("unfired-subscription-grace")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await ObserverRowsTests().owner(space.sessions)
      let slot = try await space.sessions.armSubscription(id, slot: .init(
        id: .init("timer"), kind: .timer(.oneShot(fixedDate.addingTimeInterval(60)), message: "tick"),
        handler: handler ? "/timer.js" : nil,
      ), nextFireAt: fixedDate.addingTimeInterval(60))
      _ = try await space.sessions.archive(id, grace: .seconds(100))
      #expect(try await space.sessions.armedSubscriptions(id) == [slot])
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.armedSubscriptions(id) == [slot])
      try await reopened.sessions.unarchive(id)
      #expect(try await reopened.sessions.armedSubscriptions(id) == [slot])
      #expect(try await reopened.sessions.undrainedInputs(id).isEmpty)
      try await reopened.sessions.cancelSubscription(.session(id), subscriptionID: slot.slot.id)
      #expect(try await space.sessions.armedSubscriptions(id).isEmpty)
      try await reopened.close()
      try await space.close()
    }
  }

  @Test func registrationObservationTracksArchiveLifecycleWithSlotsPreserved() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await ObserverRowsTests().owner(store)
      _ = try await ObserverRowsTests().arm(store, id)
      let lifecycle = Collector<Bool>()
      let registrations = store.observeArmedSubscriptions()
      let task = Task {
        do {
          for try await snapshot in registrations {
            if let first = snapshot.first { await lifecycle.append(first.orphaned) }
          }
        } catch { Issue.record(error) }
      }
      defer { task.cancel() }
      _ = try await awaitItems(lifecycle, atLeast: 1)
      _ = try await store.archive(id, grace: .seconds(100))
      _ = try await awaitItems(lifecycle, atLeast: 2)
      try await store.unarchive(id)
      let snapshots = try await awaitItems(lifecycle, atLeast: 3)
      #expect(snapshots == [false, true, false])
      #expect(try await store.subscriptionRegistrations().first?.orphaned == false)
      #expect(try await store.armedSubscriptions(id).count == 1)
    }
  }

  @Test(arguments: [false, true])
  func archivedRetirementIsConditionalAndSilent(handler: Bool) async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await ObserverRowsTests().owner(store)
      let slot = try await store.armSubscription(id, slot: .init(
        id: .init("timer"), kind: .timer(.oneShot(fixedDate), message: "tick"), handler: handler ? "/timer.js" : nil,
      ), nextFireAt: fixedDate)
      #expect(try await !store.retireOrphanedSubscription(.session(id), subscriptionID: slot.slot.id))
      #expect(try await store.armedSubscriptions(id) == [slot])
      _ = try await store.archive(id, grace: .seconds(100))
      try await store.unarchive(id)
      #expect(try await !store.retireOrphanedSubscription(.session(id), subscriptionID: slot.slot.id))
      #expect(try await store.armedSubscriptions(id) == [slot])
      _ = try await store.archive(id, grace: .seconds(100))
      #expect(try await store.retireOrphanedSubscription(.session(id), subscriptionID: slot.slot.id))
      #expect(try await !store.retireOrphanedSubscription(.session(id), subscriptionID: slot.slot.id))
      try await store.unarchive(id)
      #expect(try await store.armedSubscriptions(id).isEmpty)
      #expect(try await store.undrainedInputs(id).isEmpty)
    }
  }

  @Test func armedSlotsAreWhatTheStoresHoldWithTheOnesThatRunAHandler() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await ObserverRowsTests().owner(store)
      let (plain, quiet, removed, observer) = (SubscriptionID("plain"), SubscriptionID("quiet"), SubscriptionID("removed"), SubscriptionID("observer"))
      _ = try await store.armSubscription(id, slot: .init(id: plain, kind: .timer(.cron("* * * * *"), message: "tick")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: quiet, kind: .timer(.cron("* * * * *"), message: "tick"), handler: "/timer.js"), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: removed, kind: .timer(.oneShot(fixedDate), message: "old")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: observer, kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/observe.js"))
      try await store.cancelSubscription(.session(id), subscriptionID: removed)
      let armed = try await store.rows { try $0.armedSlots(id) }
      #expect(armed.slots == [plain: .timer(.cron("* * * * *")), quiet: .timer(.cron("* * * * *")), observer: .observe(sql: "SELECT 1")])
      #expect(armed.handlers == [quiet, observer])
    }
  }
}
