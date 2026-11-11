import Foundation
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite struct ArmedTests {
  @Test func `a slot has a row from the item that arms it to the item that ends it`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let (plain, quiet, watch) = (SubscriptionID("timer.plain"), SubscriptionID("timer.quiet"), SubscriptionID("obs.watch"))
      let (once, yearly) = (TimerSchedule.oneShot(anchor.addingTimeInterval(60)), TimerSchedule.cron("0 0 1 1 *"))
      let script = InferenceScript([
        Fix.replying("arming", calls: ["plain", "quiet", "watch"].map { ToolCall(id: $0, name: $0, arguments: .object([:])) }),
        Fix.replying("cancelling", calls: [ToolCall(id: "cancel", name: "cancel", arguments: .object([:]))]),
        Fix.replying("armed"),
        Fix.replying("nothing"),
        Fix.replying("nothing"),
      ])
      let config = makeConfig(executeTool: { call in
        switch call.name {
        case "plain":
          let payload = ToolResultPayload.timer(.init(subscriptionID: plain, schedule: once, message: "ping"))
          return try await sessions.armTimer(sid, timer: plain, schedule: once, message: "ping", due: anchor.addingTimeInterval(60), answering: ToolReceipt(session: sid, callID: .init("tc-plain"), payload: payload))
        case "quiet":
          _ = try await sessions.armSubscription(sid, slot: .init(id: quiet, kind: .timer(yearly, message: "unused"), handler: "/quiet.js"), nextFireAt: anchor.addingTimeInterval(86400))
          return .timer(.init(subscriptionID: quiet, schedule: yearly, message: "unused"))
        case "watch":
          _ = try await sessions.armSubscription(sid, slot: .init(id: watch, kind: .observe(sql: "SELECT 1", throttleSeconds: 30)), nextFireAt: nil)
          return .observe(.init(subscriptionID: watch, source: .query("SELECT 1")))
        default:
          try await sessions.cancelSubscription(.session(sid), subscriptionID: watch)
          return .cancelObservation(.init(subscriptionID: watch))
        }
      }, inference: { try await script($0) })
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("arm them"), to: sid)
        try await until("it armed three and cancelled one") { try await sessions.settledWork(sid) && script.count == 3 }
        #expect(try await armed(space) == ["timer.plain": false, "timer.quiet": true])
        // The handler's slot ends without an item, and the one-shot's last notice is drained with the message, whether or not its own wake came first. Time keeps moving so the worker's scan does: the jump takes the cell past its idle eviction.
        try await sessions.cancelSubscription(.session(sid), subscriptionID: quiet)
        await time.advance(by: 60)
        try await service.enqueue(item: Fix.message("anything left?"), to: sid)
        try await until("the one-shot's last notice ended its row") {
          await time.advance(by: 1)
          guard try await sessions.settledWork(sid) else { return false }
          return try await armed(space)["timer.plain"] == nil
        }
      }
    }
  }
}

private func armed(_ space: Space) async throws -> [String: Bool] {
  try await space.sessions.writer.read { db in
    Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, handler FROM session_armed").map { ($0["id"] as String, $0["handler"] as Bool) })
  }
}
