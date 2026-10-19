import Foundation
import LoopCore
import MainHub
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
import Testing

@Suite struct RequestStallFiringTests {
  @Test func anInProcessScriptHoldsTheStallClockUntilItEnds() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let parent = try await makeSession(space)
      let task = try await space.sessions.createSession(
        group: .shared, title: "child", kind: .task, parent: parent, createdBy: parent.rawValue,
        executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )
      let request = RequestID("r1")
      _ = try await space.sessions.openRequest(
        on: task, from: parent, messageID: MessageID(request.rawValue), text: "watch CI", deadline: nil, stallSeconds: 600,
      )
      let owner = Hub(space: space)
      let worker = await firingWorker(owner)

      func slot() async throws -> ArmedSubscription? {
        try await space.sessions.armedSubscriptions(parent).first { $0.slot.id == .stall(request) }
      }
      func alerts() async throws -> [SystemNotification] {
        try await space.sessions.hydrate(parent).undrained.compactMap { entry in
          guard case let .notification(notification) = entry.input, notification.kind == .requestStall else { return nil }
          return notification
        }
      }

      let firing = SubscriptionFiring(space: space, worker: worker)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await worker.drain() }
        group.addTask { await firing.run() }
        defer { group.cancelAll() }
        var world = ToolWorld(worker: worker, owner: owner, session: task)
        _ = try await world.run("run_script", .object(["source": "result('watching'); await sleep(3_600_000)"]))
        let script = try #require(await worker.activity().scripts.first { $0.value == task }?.key)
        // Past twice the stall, the clock has been checked and pushed out
        // without a word to the parent.
        try await untilAdvancing("the stall clock is checked past its stall", time, stepSeconds: 10) {
          guard let due = try await slot()?.nextFireAt else { return false }
          return due > anchor.addingTimeInterval(1200)
        }
        #expect(try await alerts().isEmpty)

        // Once the script ends, the clock runs again from where it stopped.
        _ = try await world.run("cancel", .object(["id": .string("script.\(script.rawValue)")]))
        try await untilAdvancing("the script is released", time) { await worker.activity().scripts.isEmpty }
        try await untilAdvancing("the stall alert", time, stepSeconds: 10) { try await !alerts().isEmpty }
        #expect(try await alerts().count == 1)
      }
    }
  }
}
