import Foundation
import GRDB
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
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let (plain, quiet, watch) = (SubscriptionID("timer.plain"), SubscriptionID("timer.quiet"), SubscriptionID("obs.watch"))
      let (once, yearly) = (TimerSchedule.oneShot(anchor.addingTimeInterval(60)), TimerSchedule.cron("0 0 1 1 *"))
      let script = InferenceScript([
        Fix.replying("arming", calls: ["plain", "quiet", "watch"].map { ToolCall(id: $0, name: $0, arguments: .object([:])) }),
        Fix.replying("cancelling", calls: [ToolCall(id: "cancel", name: "cancel", arguments: .object([:]))]),
        Fix.replying("folding", calls: [fold("first")]),
        { request in
          #expect(request.transcript.armed == [plain: .timer(once), quiet: .timer(yearly)])
          return Fix.reply("armed")
        },
        Fix.replying("folding", calls: [fold("second")]),
        { request in
          #expect(request.transcript.armed == [plain: .timer(once)])
          return Fix.reply("the handler's is gone")
        },
        Fix.replying("nothing"),
        Fix.replying("nothing"),
      ])
      let config = makeConfig(executeTool: { call in
        switch call.name {
        case "plain":
          return try await space.arm(sid, .init(id: plain, kind: .timer(once, message: "ping")), nextFireAt: anchor.addingTimeInterval(60), answering: "plain")
        case "quiet":
          return try await space.arm(sid, .init(id: quiet, kind: .timer(yearly, message: "unused"), handler: "/quiet.js"), nextFireAt: anchor.addingTimeInterval(86400), answering: "quiet")
        case "watch":
          return try await space.arm(sid, .init(id: watch, kind: .observe(sql: "SELECT 1", throttleSeconds: 30)), answering: "watch")
        default:
          return try await space.disarm(sid, watch, answering: "cancel")!
        }
      }, inference: { try await script($0) })
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("arm them"), to: sid)
        try await until("it armed three, cancelled one and folded") { try await sessions.settledWork(sid) && script.count == 4 }
        #expect(try await armed(space) == ["timer.plain": false, "timer.quiet": true])
        // A call that already ran gets its answer and arms nothing; a slot that ended is as unknown as one that never was.
        #expect(try await space.arm(sid, .init(id: plain, kind: .timer(yearly, message: "again")), nextFireAt: anchor, answering: "plain") == .timer(.init(subscriptionID: plain, schedule: once, message: "ping")))
        #expect(try await space.disarm(sid, watch, answering: "cancel") == .cancelObservation(.init(subscriptionID: watch)))
        #expect(try await space.disarm(sid, watch, answering: "cancel-again") == nil)
        #expect(try await armed(space) == ["timer.plain": false, "timer.quiet": true])
        // The handler's row is its observer's: the cancel deletes the session's row and mails the observer, which deletes its own.
        #expect(try await space.disarm(sid, quiet, answering: "cancel-quiet") == .cancelTimer(.init(subscriptionID: quiet)))
        try await until("the observer ended its slot") { try await sessions.armedSubscriptions(sid).isEmpty }
        try await service.enqueue(item: Fix.message("fold again"), to: sid)
        try await until("it folded again") { try await sessions.settledWork(sid) && script.count == 6 }
        #expect(try await armed(space) == ["timer.plain": false])
        // The one-shot's last notice is drained with the message, whether or not its own wake came first. Time keeps moving so the worker's scan does: the jump takes the cell past its idle eviction.
        await time.advance(by: 60)
        try await service.enqueue(item: Fix.message("anything left?"), to: sid)
        try await until("the one-shot's last notice ended its row") {
          await time.advance(by: 1)
          guard try await sessions.settledWork(sid) else { return false }
          return try await armed(space)["timer.plain"] == nil
        }
        #expect(try await space.disarm(sid, plain, answering: "cancel-fired") == nil)
      }
    }
  }
}

private func fold(_ id: String) -> ToolCall {
  ToolCall(id: id, name: "compact", arguments: .object(["summary": .string("so far")]))
}

private extension Transcript {
  /// What the generation's head says the session had armed.
  var armed: [SubscriptionID: Subscription] {
    guard case let .generationHead(head)? = items.first else { return [:] }
    return head.snapshot.subscriptions
  }
}

private func armed(_ space: Space) async throws -> [String: Bool] {
  try await space.sessions.writer.read { db in
    Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, handler FROM session_armed").map { ($0["id"] as String, $0["handler"] as Bool) })
  }
}
