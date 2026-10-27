import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
@_spi(SessionObservation) @testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct ObserverStoreTests {
  let tests = SubscriptionHandlerTests()

  func arm(_ store: SessionStore, _ name: String = "triage", cap: Int = 2) async throws -> ArmedSubscription {
    try await store.armObserver(.shared, ObserverTerms(name: name, sessionsPerHour: cap), slot: .init(
      id: .init("obs.\(name)"), kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/\(name).js",
    ))
  }

  @Test func armListCancelKeepNamesUniquePerGroupAndRefuseByCode() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let armed = try await arm(store)
      #expect(armed.owner == .group(.shared))
      #expect(armed.name == "triage")
      #expect(armed.status == .armed)
      #expect(armed.sessionsPerHour == 2)
      await #expect(throws: ObserverRefusal.nameTaken("triage")) { _ = try await arm(store) }
      for name in ["Triage", "-x", "a_b", String(repeating: "a", count: 65)] {
        #expect(throws: ObserverRefusal.invalidName(name)) { _ = try ObserverTerms(name: name) }
      }
      #expect(throws: ObserverRefusal.invalidCap(0)) { _ = try ObserverTerms(name: "x", sessionsPerHour: 0) }
      await #expect(throws: ObserverRefusal.handlerRequired) {
        _ = try await store.armObserver(.shared, ObserverTerms(name: "bare"), slot: .init(id: .init("bare"), kind: .timer(.cron("* * * * *"), message: "")))
      }
      await #expect(throws: SpaceError.self) {
        _ = try await store.armObserver(GroupID(rawValue: "no-such-group"), ObserverTerms(name: "x"), slot: armed.slot)
      }
      _ = try await arm(store, "digest")
      #expect(try await store.observers(.shared).map(\.name) == ["digest", "triage"])
      #expect(try await space.query("SELECT name, session_id, status, sessions_per_hour, handler FROM subscriptions WHERE name = 'triage'").rows == [
        [.text("triage"), .null, .text("armed"), .integer(2), .text("/triage.js")],
      ])
      #expect(try await store.cancelObserver(.shared, name: "triage").slot.id == armed.slot.id)
      await #expect(throws: ObserverRefusal.unknownObserver("triage")) { _ = try await store.cancelObserver(.shared, name: "triage") }
      #expect(try await store.observers(.shared).map(\.name) == ["digest"])
    }
  }

  @Test func capPausesTheObserverUntilArmedAgain() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let armed = try await arm(store, cap: 2)
      let observer = Observer(group: .shared, name: "triage", firing: "f1")
      @Sendable func make(_ call: Int) async throws -> SessionID {
        try await store.createSession(
          group: .shared, title: "made", kind: .agent, createdBy: observer.member, executor: .kernel(.test),
          receipt: (.observer(observer), ToolCallID("call-\(call)")), observer: observer,
        )
      }
      let first = try await make(0)
      let outcomes = await withTaskGroup(of: String.self) { group in
        for call in 1 ... 4 {
          group.addTask {
            do { _ = try await make(call); return "made" } catch { return "\(error)" }
          }
        }
        return await group.reduce(into: [String]()) { $0.append($1) }
      }
      let atCap = ObserverRefusal.atCap(name: "triage", sessionsPerHour: 2)
      #expect(outcomes.sorted() == ["made", atCap.description, "\(ObserverRefusal.paused("triage"))", "\(ObserverRefusal.paused("triage"))"])
      #expect(try await make(0) == first)
      let paused = try #require(try await store.observers(.shared).first)
      #expect(paused.status == .paused)
      #expect(paused.slot.lastError == ObserverRefusal.atCap(name: "triage", sessionsPerHour: 2).description)
      #expect(try await store.beginSubscriptionHandler(.group(.shared), subscriptionID: armed.slot.id, incarnation: try #require(armed.slot.handlerIncarnation)) == nil)
      let resumed = try await arm(store, cap: 3)
      #expect(resumed.status == .armed)
      #expect(resumed.slot.lastError == nil)
      _ = try await make(5)
    }
  }

  @Test func firingLogsWhatItMadeDropsWakesAndPrunesWeekOldEmptyFirings() async throws {
    let rig = try MovingClockSpace()
    let store = rig.store
    try await withDependencies { $0.uuid = .incrementing } operation: {
      let armed = try await arm(store)
      let made = try await tests.begin(store, armed)
      #expect(made.group == .shared)
      #expect(made.name == "triage")
      let child = try await store.createSession(
        group: .shared, title: "made", kind: .agent, createdBy: "triage@shared", executor: .kernel(.test), observer: Observer(group: .shared, name: "triage", firing: made.firing),
      )
      #expect(try await store.finishSubscriptionHandler(made, result: .success(stateJSON: "1", advance: .observed(marker: "a"), wakes: [tests.wake(armed, "nobody hears")])))
      let empty = try await tests.begin(store, armed, marker: "b")
      #expect(try await store.finishSubscriptionHandler(empty, result: .failure(error: "boom", notification: tests.wake(armed, "boom"))))
      let log = "SELECT id, owner_kind, name, outcome, error, effects FROM subscription_firings ORDER BY at, id"
      #expect(try await rig.space.query(log).rows == [
        [.text(made.firing), .text("group"), .text("triage"), .text("ok"), .null, .text(#"{"sessions":["\#(child.rawValue)"]}"#)],
        [.text(empty.firing), .text("group"), .text("triage"), .text("failed"), .text("boom"), .null],
      ])
      #expect(try await store.observers(.shared).first?.marker == "a")

      let wrote = try await tests.begin(store, armed, marker: "b")
      #expect(try await rig.space.query("SELECT outcome FROM subscription_firings WHERE id = ?", arguments: [.string(wrote.firing)]).rows == [[.text("running")]])
      let writer = Observer(group: .shared, name: "triage", firing: wrote.firing)
      _ = try await rig.space.fs(.shared, attribution: RevisionAttribution(firing: writer)).write("/note.md", Data("x".utf8), ifMatch: nil)
      #expect(try await store.finishSubscriptionHandler(wrote, result: .success(stateJSON: "2", advance: .observed(marker: "b"), wakes: [])))
      let wroteEffects = try await rig.space.query("SELECT effects FROM subscription_firings WHERE id = ?", arguments: [.string(wrote.firing)]).rows
      guard case let .text(effects)? = wroteEffects.first?.first else { Issue.record("a firing that wrote logs its revisions"); return }
      #expect(effects.hasPrefix(#"{"revisions":[""#))

      rig.advance(SessionStore.noEffectFiringRetention + 1)
      let later = try await tests.begin(store, armed, marker: "c")
      _ = try await store.finishSubscriptionHandler(later, result: .success(stateJSON: "3", advance: .observed(marker: "c"), wakes: []))
      #expect(try await rig.space.query("SELECT id FROM subscription_firings ORDER BY at").rows == [[.text(made.firing)], [.text(wrote.firing)], [.text(later.firing)]])

      let cut = try await tests.begin(store, armed, marker: "d")
      let stranded = try await tests.begin(store, try await arm(store, "digest"))
      _ = try await store.cancelObserver(.shared, name: "triage")
      #expect(try await store.finishSubscriptionHandler(cut, result: .success(stateJSON: "4", advance: .observed(marker: "d"), wakes: [])) == false)
      try await store.interruptFirings()
      let ends = "SELECT outcome FROM subscription_firings WHERE id IN (?, ?) ORDER BY name"
      #expect(try await rig.space.query(ends, arguments: [.string(cut.firing), .string(stranded.firing)]).rows == [[.text("interrupted")], [.text("cancelled")]])
    }
  }
}
