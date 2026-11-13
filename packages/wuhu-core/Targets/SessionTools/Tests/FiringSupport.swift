#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import class MainHub.Hub
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import StructuredQueries

// Parks until the task is cancelled, then runs `then`: what a test's worker
// or scripts do when its task group ends.
func whenCancelled(_ then: @Sendable () async -> Void) async {
  let (parked, end) = AsyncStream<Void>.makeStream()
  for await _ in parked {}
  end.finish()
  await then()
}

func firingWorker(_ loop: ToolFixture, owner: Hub) async throws -> SessionExecution {
  SessionRuntime.bindMain(owner: owner, execution: loop.execution, tokens: loop.tokens, connection: loop.connection)
  loop.execution.start()
  return loop.execution
}

@Table("session_queue")
private struct FiringQueueRow {
  let id: Int64
  @Column("session_id") let sessionID: String
  let payload: String
  @Column("due_at") let dueAt: String?
}

extension SessionCell {
  func firingInputs(delayedOnly: Bool = false) throws -> [QueueInput] {
    try db.rows(FiringQueueRow.where { $0.sessionID.eq(id.key) }.order { $0.id })
      .filter { !delayedOnly || $0.dueAt != nil }.map {
        try JSONDecoder().decode(QueueInput.self, from: Data($0.payload.utf8))
      }
  }
}
