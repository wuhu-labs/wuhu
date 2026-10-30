import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@_spi(SessionObservation) @testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct RetiringSlotTests {
  let handlers = SubscriptionHandlerTests()

  func cancel(_ store: SessionStore, _ id: SessionID, _ slot: ArmedSubscription, call: String) async throws -> ToolResultPayload {
    try await store.cancelSubscription(id, subscriptionID: slot.slot.id, answering: ToolCallID(call)) { stored in
      guard stored != nil else { throw Refused() }
      return .cancelObservation(.init(subscriptionID: slot.slot.id))
    }
  }

  struct Refused: Error {}

  func firings(_ space: Space) async throws -> [[Cell]] {
    try await space.query("SELECT outcome FROM subscription_firings ORDER BY at, id").rows
  }

  @Test func aCancelDuringAFiringRetiresTheSlotWhenThatFiringEndsWithItsWakes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await handlers.owner(store)
      let slot = try await handlers.arm(store, id)
      let attempt = try await handlers.begin(store, slot, marker: "m")
      _ = try await cancel(store, id, slot, call: "tc-cancel")
      await #expect(throws: Refused.self) { try await cancel(store, id, slot, call: "tc-again") }
      #expect(try await space.query("SELECT id FROM subscriptions", as: space.principal(of: id)).rows.isEmpty)
      #expect(try await store.finishSubscriptionHandler(attempt, result: .success(
        stateJSON: "{\"dropped\":true}", advance: .observed(marker: "m"), wakes: [handlers.wake(slot, "before"), handlers.wake(slot, "after")],
      )))
      #expect(try await store.armedSubscriptions(id).isEmpty)
      let woken = try await store.hydrate(id).undrained.compactMap { entry -> SystemNotification? in
        guard case let .notification(notification) = entry.input else { return nil }
        return notification
      }
      #expect(woken.map(\.content.text) == ["before", "after"])
      #expect(woken.map(\.endsSubscription) == [true, true])
      #expect(try await firings(space) == [[.text("ok")]])
    }
  }

  @Test func aRetiringSlotNeverFiresAgainAndGoesWithItsCutOffFiring() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await handlers.owner(store)
      let slot = try await handlers.arm(store, id)
      let attempt = try await handlers.begin(store, slot)
      _ = try await cancel(store, id, slot, call: "tc-cancel")
      #expect(try await store.registeredSubscriptions(id).ids.isEmpty)
      let incarnation = try #require(slot.slot.handlerIncarnation)
      #expect(try await store.beginSubscriptionHandler(slot.owner, subscriptionID: slot.slot.id, incarnation: incarnation) == nil)
      try await store.cancelFiring(attempt)
      #expect(try await store.armedSubscriptions(id).isEmpty)
      #expect(try await firings(space) == [[.text("cancelled")]])
    }
  }

  @Test func aRetiringSlotWhoseFiringFailsEndsFailedWithoutItsWakes() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await handlers.owner(store)
      let slot = try await handlers.arm(store, id)
      let attempt = try await handlers.begin(store, slot)
      _ = try await cancel(store, id, slot, call: "tc-cancel")
      #expect(try await store.finishSubscriptionHandler(attempt, result: .failure(error: "timed out", notification: handlers.wake(slot, "failed"))))
      #expect(try await store.armedSubscriptions(id).isEmpty)
      let woken = try await store.hydrate(id).undrained.compactMap { entry -> SystemNotification? in
        guard case let .notification(notification) = entry.input else { return nil }
        return notification
      }
      #expect(woken.map(\.content.text) == ["failed"])
      #expect(woken.map(\.endsSubscription) == [true])
      #expect(try await firings(space) == [[.text("failed")]])
    }
  }

  @Test func aSlotWithNoFiringIsCancelledAtOnce() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await handlers.owner(store)
      let slot = try await handlers.arm(store, id)
      _ = try await cancel(store, id, slot, call: "tc-cancel")
      #expect(try await store.armedSubscriptions(id).isEmpty)
    }
  }

  @Test(arguments: [false, true]) func aRetiringSlotWhoseFiringIsCutOffGoesWithIt(archived: Bool) async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await handlers.owner(store)
      let slot = try await handlers.arm(store, id)
      let other = try await store.armSubscription(id, slot: .init(id: .init("other"), kind: .observe(sql: "SELECT 2", throttleSeconds: 30), handler: "/watch.js"))
      _ = try await handlers.begin(store, slot)
      _ = try await cancel(store, id, slot, call: "tc-cancel")
      if archived {
        _ = try await store.archive(id, grace: .seconds(100))
      } else {
        try await store.interruptFirings()
        #expect(try await firings(space) == [[.text("interrupted")]])
      }
      #expect(try await store.armedSubscriptions(id).map(\.slot.id) == [other.slot.id])
    }
  }
}
