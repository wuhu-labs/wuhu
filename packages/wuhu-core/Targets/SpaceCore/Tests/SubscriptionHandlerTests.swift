import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import Scratch
import SessionDomain
import struct SpaceContract.GroupID
@_spi(SessionObservation) @testable import SpaceCore
import Testing

@Suite struct SubscriptionHandlerTests {
  func owner(_ store: SessionStore, group: GroupID = .shared) async throws -> SessionID {
    try await store.createSession(group: group, title: "watch", kind: .agent, createdBy: "morgan", model: .test)
  }

  func arm(_ store: SessionStore, _ id: SessionID) async throws -> ArmedSubscription {
    try await store.armSubscription(id, slot: .init(
      id: .init("watch"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/watch.js",
    ))
  }

  func begin(_ store: SessionStore, _ slot: ArmedSubscription, marker: String? = nil) async throws -> SubscriptionHandlerAttempt {
    let incarnation = try #require(slot.slot.handlerIncarnation)
    return try #require(try await store.beginSubscriptionHandler(
      slot.session, subscriptionID: slot.slot.id, incarnation: incarnation, marker: marker,
    ))
  }

  func wake(_ slot: ArmedSubscription, _ text: String) -> SystemNotification {
    .init(id: UUID(), timestamp: fixedDate, kind: .spaceObservation, subscriptionID: slot.slot.id, content: .init(text: text))
  }

  @Test func legacyPayloadDecodesWithoutHandlerFieldsAndArmingRetryKeepsItsTruth() async throws {
    struct LegacySlot: Codable { var id: SubscriptionID; var kind: SubscriptionSlot.Kind }
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let legacy = LegacySlot(id: .init("legacy"), kind: .timer(.oneShot(fixedDate), message: "tick"))
      let decoded = try Sessions.decode(SubscriptionSlot.self, from: Sessions.encode(legacy))
      #expect(decoded.handler == nil)
      #expect(decoded.handlerStateJSON == nil)
      #expect(decoded.handlerIncarnation == nil)
      #expect(decoded.lastError == nil)
      let original = try await arm(store, id)
      let retry = try await store.armSubscription(id, slot: .init(id: original.slot.id, kind: .timer(.oneShot(fixedDate), message: "different"), handler: "/different.js"))
      #expect(retry == original)
      #expect(original.armedAt == fixedDate)
      #expect(original.slot.handlerStateJSON == nil)
    }
  }

  @Test func successfulFinishAtomicallyAdvancesCanonicalStateMarkerAndWakesWithStableCallback() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let slot = try await arm(store, id)
      let initialCallback = observationToken(slot)
      let attempt = try await begin(store, slot, marker: "first")
      #expect(attempt.stateJSON == nil)
      #expect(try await store.armedSubscriptions(id).first?.lastFiredAt == fixedDate)
      #expect(try await store.hydrate(id).undrained.isEmpty)
      #expect(try await store.finishSubscriptionHandler(attempt, result: .success(
        stateJSON: #"{"z":2,"cursor":1}"#, advance: .observed(marker: "first"), wakes: [wake(slot, "release")],
      )))
      let advanced = try #require(try await store.armedSubscriptions(id).first)
      #expect(advanced.slot.handlerStateJSON == #"{"cursor":1,"z":2}"#)
      #expect(advanced.marker == "first")
      #expect(observationToken(advanced) == initialCallback)
      #expect(advanced.slot.handlerIncarnation == slot.slot.handlerIncarnation)
      #expect(try await store.hydrate(id).undrained.count == 1)
      #expect(try await store.beginSubscriptionHandler(id, subscriptionID: slot.slot.id, incarnation: try #require(slot.slot.handlerIncarnation), marker: "first") == nil)
      #expect(try await !store.finishSubscriptionHandler(attempt, result: .success(stateJSON: "null", advance: .observed(marker: "again"), wakes: [wake(slot, "duplicate")])))
      #expect(try await store.hydrate(id).undrained.count == 1)
      let next = try await begin(store, advanced, marker: "second")
      #expect(next.stateJSON == #"{"cursor":1,"z":2}"#)
    }
  }

  @Test func failureKeepsStateAndMarkerAndWakesOnceUntilSuccess() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let slot = try await arm(store, id)
      let first = try await begin(store, slot)
      _ = try await store.finishSubscriptionHandler(first, result: .success(stateJSON: "7", advance: .observed(marker: "saved"), wakes: []))
      for message in ["throw", "timeout", "missing file"] {
        let attempt = try await begin(store, slot, marker: "new")
        #expect(attempt.stateJSON == "7")
        #expect(try await store.finishSubscriptionHandler(attempt, result: .failure(error: message, notification: wake(slot, message))))
      }
      let failed = try #require(try await store.armedSubscriptions(id).first)
      #expect(failed.slot.handlerStateJSON == "7")
      #expect(failed.marker == "saved")
      #expect(failed.slot.lastError == "missing file")
      #expect(try await store.hydrate(id).undrained.count == 1)
      let recover = try await begin(store, slot, marker: "new")
      _ = try await store.finishSubscriptionHandler(recover, result: .success(stateJSON: "8", advance: .observed(marker: "new"), wakes: []))
      #expect(try await store.armedSubscriptions(id).first?.slot.lastError == nil)
      let freshFailure = try await begin(store, slot, marker: "newer")
      _ = try await store.finishSubscriptionHandler(freshFailure, result: .failure(error: "again", notification: wake(slot, "again")))
      #expect(try await store.hydrate(id).undrained.count == 2)
    }
  }

  @Test func cancelledAndRearmedSlotRejectsOldFinishAndOldBegin() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let slot = try await arm(store, id)
      let attempt = try await begin(store, slot)
      try await store.cancelSubscription(id, subscriptionID: slot.slot.id)
      #expect(try await !store.finishSubscriptionHandler(attempt, result: .failure(error: "late", notification: wake(slot, "late"))))
      let replacement = try await arm(store, id)
      #expect(replacement.slot.handlerIncarnation != slot.slot.handlerIncarnation)
      #expect(observationToken(replacement) != observationToken(slot))
      #expect(try await store.beginSubscriptionHandler(id, subscriptionID: slot.slot.id, incarnation: try #require(slot.slot.handlerIncarnation)) == nil)
      #expect(try await !store.finishSubscriptionHandler(attempt, result: .success(stateJSON: "1", advance: .retire, wakes: [wake(slot, "late")])))
      #expect(try await store.armedSubscriptions(id) == [replacement])
      #expect(try await store.hydrate(id).undrained.isEmpty)
    }
  }

  @Test func invalidStateAndNonadvancingScheduleRollBackAllFinishWrites() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let slot = try await store.armSubscription(id, slot: .init(id: .init("timer"), kind: .timer(.cron("* * * * *"), message: "tick"), handler: "/timer.js"), nextFireAt: fixedDate)
      let attempt = try await begin(store, slot)
      for json in ["undefined", String(repeating: " ", count: 16 * 1024 + 1)] {
        await #expect(throws: SubscriptionHandlerStateError.self) {
          _ = try await store.finishSubscriptionHandler(attempt, result: .success(stateJSON: json, advance: .reschedule(fixedDate.addingTimeInterval(60)), wakes: [wake(slot, "bad")]))
        }
      }
      await #expect(throws: NonAdvancingSubscription.self) {
        _ = try await store.finishSubscriptionHandler(attempt, result: .success(stateJSON: "1", advance: .reschedule(fixedDate), wakes: [wake(slot, "bad")]))
      }
      #expect(try await store.hydrate(id).undrained.isEmpty)
      #expect(try await store.armedSubscriptions(id).first?.slot.handlerStateJSON == nil)
      #expect(try await store.finishSubscriptionHandler(attempt, result: .failure(error: "retry", notification: wake(slot, "retry"), advance: .reschedule(fixedDate.addingTimeInterval(60)))))
      let failed = try #require(try await store.armedSubscriptions(id).first)
      #expect(failed.nextFireAt == fixedDate.addingTimeInterval(60))
      #expect(failed.slot.handlerStateJSON == nil)
      let retry = try await begin(store, failed)
      #expect(try await store.finishSubscriptionHandler(retry, result: .success(stateJSON: "null", advance: .retire, wakes: [wake(slot, "done")])))
      #expect(try await store.armedSubscriptions(id).isEmpty)
      #expect(try await store.hydrate(id).undrained.count == 2)
    }
  }

  @Test func realReopenRerunsSavedStateAndPersistsFailureStreakAndCancellation() async throws {
    let folder = try ScratchFolder("subscription-handler-reopen")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      var space: Space? = try Space.open(file: file)
      let id = try await owner(try #require(space).sessions)
      let slot = try await arm(try #require(space).sessions, id)
      let success = try await begin(try #require(space).sessions, slot)
      _ = try await space?.sessions.finishSubscriptionHandler(success, result: .success(stateJSON: #"{"cursor":5}"#, advance: .observed(marker: "saved"), wakes: []))
      let failed = try await begin(try #require(space).sessions, slot, marker: "pending")
      _ = try await space?.sessions.finishSubscriptionHandler(failed, result: .failure(error: "offline", notification: wake(slot, "offline")))
      let inFlight = try await begin(try #require(space).sessions, slot, marker: "pending")
      space = nil
      let reopened = try Space.open(file: file)
      let restored = try #require(try await reopened.sessions.armedSubscriptions(id).first)
      #expect(restored.slot.handlerStateJSON == #"{"cursor":5}"#)
      #expect(restored.slot.lastError == "offline")
      #expect(restored.marker == "saved")
      #expect(restored.armedAt == fixedDate)
      #expect(restored.lastFiredAt == fixedDate)
      let replay = try await begin(reopened.sessions, restored, marker: "pending")
      #expect(replay.stateJSON == #"{"cursor":5}"#)
      #expect(try await !reopened.sessions.finishSubscriptionHandler(inFlight, result: .success(stateJSON: "6", advance: .observed(marker: "pending"), wakes: [wake(slot, "stale")])))
      _ = try await reopened.sessions.finishSubscriptionHandler(replay, result: .failure(error: "still offline", notification: wake(slot, "still offline")))
      #expect(try await reopened.sessions.hydrate(id).undrained.count == 1)
      try await reopened.sessions.cancelSubscription(id, subscriptionID: slot.slot.id)
      #expect(try await Space.open(file: file).sessions.armedSubscriptions(id).isEmpty)
    }
  }

  @Test func startOverAndCompactionKeepHandlersArchivePreservesSavedState() async throws {
    let folder = try ScratchFolder("subscription-handler-archive")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      let space = try Space.open(file: file)
      let id = try await owner(space.sessions)
      let slot = try await arm(space.sessions, id)
      let attempt = try await begin(space.sessions, slot)
      _ = try await space.sessions.finishSubscriptionHandler(attempt, result: .success(stateJSON: "1", advance: .observed(marker: "saved"), wakes: []))
      let saved = try await space.sessions.armedSubscriptions(id)
      _ = try await space.sessions.restart(id)
      #expect(try await space.sessions.armedSubscriptions(id) == saved)
      _ = try await space.sessions.writeCompaction(id, head: .init(id: UUID(), timestamp: fixedDate, summary: "summary", snapshot: .init(), runningWork: []), kept: nil)
      #expect(try await space.sessions.armedSubscriptions(id) == saved)
      let late = try await begin(space.sessions, slot)
      _ = try await space.sessions.archive(id, grace: .seconds(100))
      #expect(try await !space.sessions.finishSubscriptionHandler(late, result: .success(stateJSON: "2", advance: .observed(marker: "late"), wakes: [wake(slot, "late")])))
      let archived = try #require(try await Space.open(file: file).sessions.armedSubscriptions(id).first)
      #expect(archived.slot.handlerStateJSON == "1")
      #expect(archived.slot.handlerIncarnation == slot.slot.handlerIncarnation)
      #expect(archived.slot.handlerAttemptID == nil)
      #expect(try await space.sessions.beginSubscriptionHandler(id, subscriptionID: slot.slot.id, incarnation: late.incarnation) == nil)
      try await space.sessions.unarchive(id)
      #expect(try await !space.sessions.finishSubscriptionHandler(late, result: .success(stateJSON: "2", advance: .observed(marker: "late"), wakes: [wake(slot, "late")])))
      let resumed = try await begin(space.sessions, archived)
      #expect(resumed.stateJSON == "1")
      #expect(try await space.sessions.hydrate(id).undrained.isEmpty)
    }
  }
}
