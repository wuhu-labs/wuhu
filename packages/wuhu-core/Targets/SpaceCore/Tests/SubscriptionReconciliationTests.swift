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
  @Test func silentHandlerRetirementReconcilesLoadedHydratedAndCompactedStateWithoutDelivery() async throws {
    let folder = try ScratchFolder("subscription-reconciliation")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      func run() async throws -> SessionID {
        let space = try Space.open(file: file)
        let store = space.sessions
        let id = try await SubscriptionHandlerTests().owner(store)
        let subscriptionID = SubscriptionID("timer.silent")
        let schedule = TimerSchedule.oneShot(fixedDate)
        let slot = try await store.armSubscription(id, slot: .init(
          id: subscriptionID, kind: .timer(schedule, message: "unused"), handler: "/silent.js",
        ), nextFireAt: fixedDate)
        let result = TranscriptItem.toolResult(.init(
          id: UUID(), timestamp: fixedDate, provenance: .toolCall(.init("timer-call")),
          payload: .timer(.init(subscriptionID: subscriptionID, schedule: schedule, message: "unused")),
        ))
        var loaded = try await store.transcript(id)
        loaded.append(result)
        try await store.append(id, items: [result], inputOrigin: loaded.cacheWarmingInputOrigin)
        loaded = try await store.transcript(id)
        let staleSnapshot = StateSnapshot(carrying: loaded.environment.tools, preReads: ["/keep.md"])
        #expect(staleSnapshot.subscriptions == [subscriptionID: .timer(schedule)])
        let before = try await store.record(id)
        let attempt = try await SubscriptionHandlerTests().begin(store, slot)
        #expect(try await store.finishSubscriptionHandler(attempt, result: .success(stateJSON: "null", advance: .retire, wakes: [])))
        #expect(try await store.armedSubscriptions(id).isEmpty)
        #expect(try await store.record(id).work == before.work)
        #expect(try await store.hydrate(id).undrained.isEmpty)
        #expect(try await store.hydrate(id).transcript.kernel.environment.tools.subscriptions.isEmpty)
        #expect(try await store.transcript(id).environment.tools.subscriptions.isEmpty)
        #expect(loaded.environment.tools.subscriptions[subscriptionID] != nil, "an already-loaded read snapshot needs refreshing")
        let registrations = try await store.registeredSubscriptions(id)
        loaded.registeredSubscriptions = registrations.ids
        loaded.handlerSubscriptions = registrations.handlers
        #expect(loaded.environment.tools.subscriptions.isEmpty)

        let compacted = try await store.writeCompaction(id, head: .init(
          id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: staleSnapshot,
          runningWork: [],
        ), kept: (loaded.items.count - 1) ..< loaded.items.count)
        #expect(compacted.items.last == result, "retained tool results cannot resurrect silently retired timers")
        #expect(compacted.environment.tools.subscriptions.isEmpty)
        guard case let .generationHead(head) = compacted.items[0] else { Issue.record("missing head"); return id }
        #expect(head.snapshot.subscriptions.isEmpty)
        #expect(head.snapshot.preReads == ["/keep.md"])
        #expect(try await store.hydrate(id).undrained.isEmpty)
        return id
      }
      let id = try await run()
      let reopened = try Space.open(file: file)
      #expect(try await reopened.sessions.hydrate(id).transcript.kernel.environment.tools.subscriptions.isEmpty)
      #expect(try await reopened.sessions.armedSubscriptions(id).isEmpty)
      #expect(try await reopened.sessions.hydrate(id).undrained.isEmpty)
    }
  }

  @Test func reconciliationPreservesArmedPublicSlotsAndDeadlineDeliverySemantics() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await SubscriptionHandlerTests().owner(store)
      let kept = SubscriptionID("timer.keep")
      let removed = SubscriptionID("timer.remove")
      let observer = SubscriptionID("observer")
      let deadline = SubscriptionID.deadline(.init("request"))
      _ = try await store.armSubscription(id, slot: .init(id: kept, kind: .timer(.cron("* * * * *"), message: "tick")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: removed, kind: .timer(.oneShot(fixedDate), message: "old")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: observer, kind: .observe(sql: "SELECT 1", throttleSeconds: 30)))
      let snapshot = StateSnapshot(subscriptions: [
        kept: .timer(.cron("* * * * *")), removed: .timer(.oneShot(fixedDate)),
        observer: .observe(sql: "SELECT 1"), deadline: .requestDeadline(fixedDate),
      ])
      _ = try await store.writeCompaction(id, head: .init(id: UUID(), timestamp: fixedDate, summary: "snapshot", snapshot: snapshot, runningWork: []), kept: nil)
      try await store.cancelSubscription(.session(id), subscriptionID: removed)
      let subscriptions = try await store.hydrate(id).transcript.kernel.environment.tools.subscriptions
      #expect(subscriptions == [kept: .timer(.cron("* * * * *")), observer: .observe(sql: "SELECT 1"), deadline: .requestDeadline(fixedDate)])
      #expect(try await store.registeredSubscriptions(id).ids == [kept, observer])
      #expect(try await store.hydrate(id).undrained.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func archiveAndUnarchivePreserveUnfiredPlainAndHandlerTimers(handler: Bool) async throws {
    let folder = try ScratchFolder("unfired-subscription-grace")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await SubscriptionHandlerTests().owner(space.sessions)
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
      #expect(try await reopened.sessions.hydrate(id).undrained.isEmpty)
      try await reopened.sessions.cancelSubscription(.session(id), subscriptionID: slot.slot.id)
      #expect(try await space.sessions.armedSubscriptions(id).isEmpty)
    }
  }

  @Test func registrationObservationTracksArchiveLifecycleWithSlotsPreserved() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await SubscriptionHandlerTests().owner(store)
      _ = try await SubscriptionHandlerTests().arm(store, id)
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
      let id = try await SubscriptionHandlerTests().owner(store)
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
      #expect(try await store.hydrate(id).undrained.isEmpty)
    }
  }

  @Test func storageProjectsHandlerIDsTogetherWithRegistrationIDsAcrossReopenAndCompaction() async throws {
    let folder = try ScratchFolder("handler-metadata")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      func armAndCompact() async throws -> SessionID {
        let space = try Space.open(file: file)
        let store = space.sessions
        let id = try await SubscriptionHandlerTests().owner(store)
        for (name, handler) in [("plain", false), ("handler", true)] {
          _ = try await store.armSubscription(id, slot: .init(
            id: .init(name), kind: .timer(.cron("* * * * *"), message: "tick"), handler: handler ? "/timer.js" : nil,
          ), nextFireAt: fixedDate)
        }
        _ = try await store.armSubscription(id, slot: .init(id: .init("observer"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/observe.js"))
        let registrations = try await store.registeredSubscriptions(id)
        #expect(registrations.ids == [.init("plain"), .init("handler"), .init("observer")])
        #expect(registrations.handlers == [.init("handler"), .init("observer")])
        let snapshot = StateSnapshot(subscriptions: [
          .init("plain"): .timer(.cron("* * * * *")), .init("handler"): .timer(.cron("* * * * *")), .init("observer"): .observe(sql: "SELECT 1"),
        ])
        let compacted = try await store.writeCompaction(id, head: .init(id: UUID(), timestamp: fixedDate, summary: "summary", snapshot: snapshot, runningWork: []), kept: nil)
        #expect(compacted.handlerSubscriptions == registrations.handlers)
        #expect(compacted.environment.tools.handlerSubscriptions == registrations.handlers)
        return id
      }
      let id = try await armAndCompact()
      let space = try Space.open(file: file)
      let hydrated = try await space.sessions.hydrate(id).transcript.kernel
      #expect(hydrated.handlerSubscriptions == [.init("handler"), .init("observer")])
      #expect(hydrated.environment.tools.handlerSubscriptions == hydrated.handlerSubscriptions)
      try await space.sessions.cancelSubscription(.session(id), subscriptionID: .init("handler"))
      let registrations = try await space.sessions.registeredSubscriptions(id)
      #expect(registrations.ids == [.init("plain"), .init("observer")])
      #expect(registrations.handlers == [.init("observer")])
    }
  }
}
