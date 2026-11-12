import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct ObserverRowsTests {
  struct Begun {
    let owner: SubscriptionOwner
    let id: SubscriptionID
    let firingID: UUID
    let group: GroupID
    let name: String?

    var firing: String { firingID.uuidString.lowercased() }
  }

  func owner(_ store: SessionStore, group: GroupID = .shared) async throws -> SessionID {
    try await store.createSession(group: group, title: "watch", kind: .agent, createdBy: "morgan", model: .test)
  }

  func arm(_ store: SessionStore, _ id: SessionID) async throws -> ArmedSubscription {
    try await store.armSubscription(id, slot: .init(
      id: .init("watch"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/watch.js",
    ))
  }

  /// A firing as its cell starts one, on rows `marker` when given.
  func begin(_ store: SessionStore, _ slot: ArmedSubscription, marker: String? = nil) async throws -> Begun {
    @Dependency(\.uuid) var uuid
    let firing = uuid()
    return try await store.writer.write { db in
      let rows = ObserverRows(db: db, store: store)
      if let marker { try rows.pend(slot.owner, slot.slot.id, .object([:]), marker: marker) }
      let group = try #require(try rows.slot(slot.owner, slot.slot.id)?.group)
      try rows.begin(slot.owner, slot.slot.id, firing: firing, group: group)
      return Begun(owner: slot.owner, id: slot.slot.id, firingID: firing, group: group, name: slot.name)
    }
  }

  /// Ends a firing as its cell does: a session owner gets the notices it is due.
  @discardableResult
  func finish(_ store: SessionStore, _ begun: Begun, _ outcome: HandlerOutcome, _ advance: ObserverAdvance = .taken(marker: nil)) async throws -> [SystemNotification] {
    let notices = try await store.writer.write { db in
      try ObserverRows(db: db, store: store).finish(
        begun.owner, begun.id, firing: begun.firingID, path: "/watch.js", kind: .spaceObservation, outcome: outcome, advance: advance, uuid: { UUID() },
      )
    }
    if case let .session(session) = begun.owner {
      for notice in notices { try await store.put(session, input: .notification(notice)) }
    }
    return notices
  }

  func slot(_ store: SessionStore, _ armed: ArmedSubscription) async throws -> ObserverSlot? {
    try await store.writer.read { db in try ObserverRows(db: db, store: store).slot(armed.owner, armed.slot.id) }
  }

  @Test func legacyPayloadDecodesWithoutHandlerFieldsAndArmingRetryKeepsItsTruth() async throws {
    struct LegacySlot: Codable { var id: SubscriptionID; var kind: SubscriptionSlot.Kind }
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let legacy = LegacySlot(id: .init("legacy"), kind: .timer(.oneShot(fixedDate), message: "tick"))
      let decoded = try Sessions.decode(SubscriptionSlot.self, from: Sessions.encode(legacy))
      #expect(decoded.handler == nil)
      #expect(decoded.handlerIncarnation == nil)
      #expect(decoded.lastError == nil)
      let original = try await arm(store, id)
      let retry = try await store.armSubscription(id, slot: .init(id: original.slot.id, kind: .timer(.oneShot(fixedDate), message: "different"), handler: "/different.js"))
      #expect(retry == original)
      #expect(original.armedAt == fixedDate)
    }
  }

  @Test func anOkFiringTakesItsRowsAndWakesItsSession() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let armed = try await arm(store, id)
      let begun = try await begin(store, armed, marker: "first")
      #expect(try await slot(store, armed)?.firing == begun.firingID)
      #expect(try await slot(store, armed)?.subscription.lastFiredAt == fixedDate)
      try await store.writer.write { db in try ObserverRows(db: db, store: store).pend(armed.owner, armed.slot.id, .object([:]), marker: "second") }
      #expect(try await finish(store, begun, .ok(wakes: ["release"]), .taken(marker: "first")).count == 1)
      let after = try #require(try await slot(store, armed))
      #expect(after.subscription.marker == "first")
      #expect(after.pendingMarker == "second", "rows that came during the firing wait for the next")
      #expect(after.firing == nil)
      #expect(try await store.undrainedInputs(id).count == 1)
    }
  }

  @Test func failuresKeepTheInputAndWakeOncePerStreak() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let armed = try await arm(store, id)
      try await finish(store, try await begin(store, armed, marker: "saved"), .ok(wakes: []), .taken(marker: "saved"))
      for message in ["throw", "timeout", "missing file"] {
        try await finish(store, try await begin(store, armed, marker: "new"), .failed(message), .taken(marker: "new"))
      }
      let failed = try #require(try await slot(store, armed))
      #expect(failed.subscription.marker == "saved")
      #expect(failed.pendingMarker == "new")
      #expect(failed.failures == 3)
      #expect(failed.subscription.slot.lastError == "missing file")
      #expect(try await store.undrainedInputs(id).count == 1)
      try await finish(store, try await begin(store, armed, marker: "new"), .ok(wakes: []), .taken(marker: "new"))
      #expect(try await slot(store, armed)?.subscription.slot.lastError == nil)
      #expect(try await slot(store, armed)?.failures == 0)
      try await finish(store, try await begin(store, armed, marker: "newer"), .failed("again"), .taken(marker: "newer"))
      #expect(try await store.undrainedInputs(id).count == 2)
    }
  }

  @Test func aFiringOutlivesItsCancelledSlotAndItsWakesAreTheLast() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let armed = try await arm(store, id)
      let begun = try await begin(store, armed, marker: "m")
      try await store.writer.write { try ObserverRows(db: $0, store: store).retire(.session(id), armed.slot.id) }
      try await finish(store, begun, .ok(wakes: ["before", "after"]), .taken(marker: "m"))
      let wakes = try await store.undrainedInputs(id).compactMap { input -> SystemNotification? in
        if case let .notification(notification) = input.input { notification } else { nil }
      }
      #expect(wakes.map(\.content.text) == ["before", "after"])
      #expect(wakes.allSatisfy { $0.endsSubscription })
      #expect(try await store.armedSubscriptions(id).isEmpty)
    }
  }

  @Test func anArchivedOwnersFiringIsCancelledAndItsSlotWaits() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await owner(store)
      let armed = try await arm(store, id)
      let begun = try await begin(store, armed, marker: "m")
      _ = try await store.archive(id, grace: .seconds(100))
      #expect(try await finish(store, begun, .ok(wakes: ["late"]), .taken(marker: "m")).isEmpty)
      let waiting = try #require(try await slot(store, armed))
      #expect(waiting.firing == nil)
      #expect(waiting.group == nil)
      #expect(waiting.pendingMarker == "m")
      #expect(try await store.undrainedInputs(id).isEmpty)
      #expect(try await store.writer.read { db in try String.fetchAll(db, sql: "SELECT outcome FROM subscription_firings") } == ["cancelled"])
    }
  }
}
