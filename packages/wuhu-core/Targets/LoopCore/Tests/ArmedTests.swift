#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing
import WuhuAI

@Suite struct ArmedTests {
  @Test func `a slot has a row from the step that arms it to the step that ends it, and a generation's head lists the ones still held`() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let (plain, quiet, watch) = (SubscriptionID("timer.plain"), SubscriptionID("timer.quiet"), SubscriptionID("obs.watch"))
      let (once, yearly) = (TimerSchedule.oneShot(anchor.addingTimeInterval(60)), TimerSchedule.cron("0 0 1 1 *"))
      let script = InferenceScript([
        Fix.replying("arming", calls: ["plain", "quiet", "watch"].map { ToolCall(id: $0, name: $0, arguments: .object([:])) }),
        Fix.replying("cancelling", calls: [ToolCall(id: "cancel", name: "cancel", arguments: .object([:]))]),
        Fix.replying("folding", calls: [fold("first")]),
        { request in
          let head = try #require(request.lines.first { $0.key == LineKey.head })
          #expect(head.text.contains("active subscriptions: timer.plain, timer.quiet\n"))
          return Fix.reply("armed")
        },
        Fix.replying("folding", calls: [fold("second")]),
        { request in
          let head = try #require(request.lines.first { $0.key == LineKey.head })
          #expect(head.text.contains("active subscriptions: timer.plain\n"))
          return Fix.reply("the handler's is gone")
        },
        Fix.replying("nothing"),
        Fix.replying("nothing"),
      ])
      let config = makeConfig(executeInvocation: { invocation in
        let sid = invocation.sessionID
        switch invocation.call.name {
        case "plain":
          return try await space.arm(sid, .init(id: plain, kind: .timer(once, message: "ping")), nextFireAt: anchor.addingTimeInterval(60))
        case "quiet":
          return try await space.arm(sid, .init(id: quiet, kind: .timer(yearly, message: "unused"), handler: "/quiet.js"), nextFireAt: anchor.addingTimeInterval(86400))
        case "watch":
          return try await space.arm(sid, .init(id: watch, kind: .observe(sql: "SELECT 1", throttleSeconds: 30)))
        default:
          return try await space.disarm(sid, watch)!
        }
      }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("arm them"), to: sid)
        try await until("it armed three, cancelled one and folded") { try await sessions.settledWork(sid) && script.count == 4 }
        #expect(try armed(space, sid) == ["timer.plain", "timer.quiet"])
        #expect(try await space.disarm(sid, watch) == nil)
        #expect(try armed(space, sid) == ["timer.plain", "timer.quiet"])
        // The handler's row is its observer's: the cancel deletes the session's row and mails the observer, which deletes its own.
        #expect(try await space.disarm(sid, quiet) == .cancelTimer(.init(subscriptionID: quiet)))
        try await until("the observer ended its slot") { try await sessions.armedSubscriptions(sid).isEmpty }
        try await service.enqueue(item: Fix.message("fold again"), to: sid)
        try await until("it folded again") { try await sessions.settledWork(sid) && script.count == 6 }
        #expect(try armed(space, sid) == ["timer.plain"])
        // The one-shot's last notice is a queued input due at its fire time: the jump passes it, and the drain follows at whichever wake
        // comes next (measured 6 to 13 s of clock, bounded at 30). One worker here, so no lease lapses to another (see `until`).
        await time.advance(by: 60)
        try await service.enqueue(item: Fix.message("anything left?"), to: sid)
        try await untilAdvancing("the one-shot's last notice ended its row", time, attempts: 30) {
          guard try await sessions.settledWork(sid) else { return false }
          return !((try armed(space, sid)).contains("timer.plain"))
        }
        #expect(try await space.disarm(sid, plain) == nil)
      }
    }
  }
}

private func fold(_ id: String) -> ToolCall {
  ToolCall(id: id, name: "compact", arguments: .object(["summary": .string("so far")]))
}

private func armed(_ space: Space, _ session: SessionID) throws -> [String] {
  try space.worker.cell(SessionCell.ID(session.rawValue)).armedSlots().keys.map(\.rawValue).sorted()
}
