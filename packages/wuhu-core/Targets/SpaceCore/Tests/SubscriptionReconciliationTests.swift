import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SubscriptionReconciliationTests {
  @Test(arguments: [false, true])
  func archiveAndUnarchivePreserveUnfiredPlainAndHandlerTimers(handler: Bool) async throws {
    let folder = try ScratchFolder("unfired-subscription-grace")
    let file = folder.url.appending(path: "space.sqlite")
    try await withSessionDeps {
      let space = registerSessionExecution(try Space.open(file: file))
      let id = try await ObserverRowsTests().owner(space.sessions)
      let slot = try await space.sessions.armSubscription(id, slot: .init(
        id: .init("timer"), kind: .timer(.oneShot(fixedDate.addingTimeInterval(60)), message: "tick"),
        handler: handler ? "/timer.js" : nil,
      ), nextFireAt: fixedDate.addingTimeInterval(60))
      _ = try await space.sessions.archive(id, grace: .seconds(100))
      #expect(try await space.sessions.armedSubscriptions(id) == [slot])
      await space.stopWorker()
      let reopened = registerSessionExecution(try Space.open(file: file))
      #expect(try await reopened.sessions.armedSubscriptions(id) == [slot])
      try await reopened.sessions.unarchive(id)
      #expect(try await reopened.sessions.armedSubscriptions(id) == [slot])
      #expect(try await reopened.sessions.undrainedInputs(id).isEmpty)
      try await reopened.close()
      try await space.close()
    }
  }

  @Test func armedSlotsAreWhatTheStoresHoldWithTheOnesThatRunAHandler() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await ObserverRowsTests().owner(store)
      let (plain, quiet, observer) = (SubscriptionID("plain"), SubscriptionID("quiet"), SubscriptionID("observer"))
      _ = try await store.armSubscription(id, slot: .init(id: plain, kind: .timer(.cron("* * * * *"), message: "tick")), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: quiet, kind: .timer(.cron("* * * * *"), message: "tick"), handler: "/timer.js"), nextFireAt: fixedDate)
      _ = try await store.armSubscription(id, slot: .init(id: observer, kind: .observe(sql: "SELECT 1", throttleSeconds: 30), handler: "/observe.js"))
      let armed = try await store.armedSubscriptions(id)
      #expect(Dictionary(uniqueKeysWithValues: armed.map { ($0.slot.id, $0.slot.kind) }) == [
        plain: .timer(.cron("* * * * *"), message: "tick"), quiet: .timer(.cron("* * * * *"), message: "tick"), observer: .observe(sql: "SELECT 1", throttleSeconds: 30),
      ])
      #expect(Set(armed.filter { $0.slot.handler != nil }.map(\.slot.id)) == [quiet, observer])
    }
  }
}
