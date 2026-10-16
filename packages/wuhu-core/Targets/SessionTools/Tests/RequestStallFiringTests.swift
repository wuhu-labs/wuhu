import Foundation
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
import Testing

// The stall check through the production firing path, with the task's script
// running in this process rather than on an execution worker.
@Suite struct RequestStallFiringTests {
  @Test func anInProcessScriptHoldsTheStallClockUntilItEnds() async throws {
    try await withRig(task: true) { rig in
      let space = rig.space
      let task = rig.session
      let parent = try #require(try await space.writer.read { try Sessions.record(task.rawValue, in: $0).parent })
      let request = RequestID("r1")
      _ = try await space.sessions.openRequest(
        on: task, from: parent, messageID: MessageID(request.rawValue), text: "watch CI", deadline: nil, stallSeconds: 600,
      )
      _ = try await rig.evaluate("result('watching'); await sleep(3_600_000)")
      let script = try #require(rig.scripts.inventory.first { $0.value == task }?.key)

      func slot() async throws -> ArmedSubscription? {
        try await space.sessions.armedSubscriptions(parent).first { $0.slot.id == .stall(request) }
      }
      func alerts() async throws -> [SystemNotification] {
        try await space.sessions.hydrate(parent).undrained.compactMap { entry in
          guard case let .notification(notification) = entry.input, notification.kind == .requestStall else { return nil }
          return notification
        }
      }

      let firing = SubscriptionFiring(space: space, scripts: rig.scripts, tools: ToolExecutor(space: space, scripts: rig.scripts))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await firing.run() }
        defer { group.cancelAll() }
        // Past twice the stall, the clock has been checked and pushed out
        // without a word to the parent.
        try await untilAdvancing("the stall clock is checked past its stall", rig.time, stepSeconds: 10) {
          guard let due = try await slot()?.nextFireAt else { return false }
          return due > anchor.addingTimeInterval(1200)
        }
        #expect(try await alerts().isEmpty)

        // Once the script ends, the clock runs again from where it stopped.
        try await rig.stop(script)
        try await rig.released()
        try await untilAdvancing("the stall alert", rig.time, stepSeconds: 10) { try await !alerts().isEmpty }
        #expect(try await alerts().count == 1)
      }
    }
  }
}
