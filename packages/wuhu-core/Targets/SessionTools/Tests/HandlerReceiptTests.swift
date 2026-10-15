import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct HandlerReceiptTests {
  @Test func failedSuccessAndFallbackWritesStillConsumeTheHandlerReceipt() async throws {
    try await withToolDeps { time in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let writes = Box<[String]>([])
      let acknowledgements = Box(0)
      let handler = FailedCommitHandlerFixture { _ in
        try await space.writer.write { db in
          db.add(function: DatabaseFunction("handler_finish_fault", argumentCount: 1) { arguments in
            writes.withLock { $0.append(String.fromDatabaseValue(arguments[0])!) }
            throw HandlerCommitFailure.injected
          })
          try db.execute(sql: """
          CREATE TEMP TRIGGER handler_success_fault BEFORE DELETE ON session_subscriptions
          BEGIN SELECT handler_finish_fault('success'); END;
          CREATE TEMP TRIGGER handler_failure_fault BEFORE UPDATE ON session_subscriptions
          BEGIN SELECT handler_finish_fault('failure'); END;
          """)
        }
        return ScriptHandlerResult(stateJSON: "{\"done\":true}", wakes: ["must roll back"], acknowledge: {
          acknowledgements.withLock { $0 += 1 }
        })
      }
      let firing = SubscriptionFiring(space: space, handler: handler)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)
      _ = try await world.run("timer", .object(["message": "unused", "in_seconds": 1, "handler": "/fixture.js"]))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await firing.run() }
        defer { group.cancelAll() }
        try await untilAdvancing("discarded result receipt consumed", time, stepSeconds: 0.1) { acknowledgements.value == 1 }
        #expect(writes.value == ["success", "failure"])
        #expect(try await space.sessions.armedSubscriptions(session).first?.slot.handlerStateJSON == nil)
        #expect(try await space.sessions.hydrate(session).undrained.isEmpty)
      }
      #expect(acknowledgements.value == 1)
    }
  }
}

private enum HandlerCommitFailure: Error { case injected }
private struct FailedCommitHandlerFixture: HandlerExecutionClient {
  let invoke: @Sendable (ScriptHandlerInvocation) async throws -> ScriptHandlerResult
  func executeHandler(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult { try await invoke(invocation) }
}
